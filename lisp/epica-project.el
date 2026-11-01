;;; epica-project.el --- project and Git tools for epica -*- lexical-binding: t; -*-

;; Optional project.el discovery, asynchronous search, and Git tools.
;; This is also an extension template: require epica, define tools,
;; and use hooks for project-specific context.
;;
;; Tools added:
;;   project-root   — where am I?
;;   project-files  — what files exist? (project.el's own discovery)
;;   project-search — find text across the project (rg/grep)
;;   find-file      — open a file into a buffer for read/edit
;;   vc-status      — what changed?
;;   vc-diff        — show me the changes
;;   vc-log         — recent history
;;   vc-commit      — stage + commit
;;
;; Plus a before-agent-start hook that injects project context into the
;; system prompt, so the model starts each turn knowing the project.

;;; Code:

(require 'epica)
(require 'epica-tools)
(require 'subr-x)
(require 'project)
(require 'vc)
(require 'cl-lib)


;;; -------------------------------------------------- context -----------

(defun epica-project--context ()
  "Inject project context into the system prompt.
Returns a string for `epica-before-agent-start-hook'."
  (when-let* ((proj (project-current)))
    (let ((root (project-root proj))
          (name (project-name proj))
          (vcs (condition-case nil
                   (vc-responsible-backend default-directory)
                 (error nil))))
      (format "Project: %s\nRoot: %s\nVCS: %s"
              name root (or vcs "none")))))

(add-hook 'epica-before-agent-start-hook #'epica-project--context)


;;; -------------------------------------------------- project tools -----

(define-epica-tool project-root
  ()
  "Return the current project's root directory.
Uses project.el — the same detection Emacs itself uses (C-x p f)."
  (if-let* ((proj (project-current)))
      (list :content (project-root proj))
    (list :content "Not in a project." :error t)))

(define-epica-tool project-files
  ((pattern string "Optional substring to filter filenames (e.g. '*.py' or 'test')." :optional t)
   (max_results integer "Max files to return (default 50)." :optional t))
  "List files in the current project (relative paths).
Uses project.el's file discovery, which respects .gitignore and project
ignores — the same list C-x p f searches."
  (if-let* ((proj (project-current)))
      (let* ((files (project-files proj))
             (filtered (if (and pattern (not (string-empty-p pattern)))
                           (cl-remove-if-not
                            (lambda (f) (string-match-p pattern f)) files)
                         files))
             (max (or max_results 50))
             (capped (cl-subseq filtered 0 (min max (length filtered)))))
        (list :content
              (format "[%d/%d files]\n%s"
                      (length capped) (length filtered)
                      (mapconcat #'identity capped "\n"))
              :details (list :total (length filtered)
                             :root (project-root proj))))
    (list :content "Not in a project." :error t)))

(defcustom epica-project-search-timeout 30
  "Seconds allowed for an asynchronous project search."
  :type 'number :group 'epica)

(defcustom epica-project-search-max-output 200000
  "Maximum characters captured from a project search before stopping it."
  :type 'integer :group 'epica)

(defun epica-project--search-async (pattern max-results callback)
  "Search the current project asynchronously for PATTERN.
Pass at most MAX-RESULTS formatted matches to CALLBACK; no search
process may block Emacs' UI."
  (let* ((proj (project-current))
         (rg (executable-find "rg"))
         (searcher (or rg (executable-find "grep")))
         (max (if (and (integerp max-results) (> max-results 0))
                  (min 500 max-results) 50)))
    (cond
     ((not proj)
      (funcall callback (list :content "Not in a project." :error t)))
     ((not searcher)
      (funcall callback
               (list :content "No search tool found (install ripgrep or grep)."
                     :error t)))
     (t
      (let* ((root (project-root proj))
             (default-directory root)
             (output (generate-new-buffer " *epica-project-search*"))
             (timer nil) (done nil) (proc nil) (truncated nil)
             (command (cons searcher
                            (if rg
                                (list "--no-heading" "-n" "--color=never"
                                      "--max-count" "100" pattern root)
                              (list "-rnI" "--exclude-dir=.git"
                                    "--color=never" pattern root)))))
        (cl-labels
            ((finish (result)
               (unless done
                 (setq done t)
                 (when timer (cancel-timer timer))
                 (when (buffer-live-p output) (kill-buffer output))
                 (funcall callback result)))
             (collect (process chunk)
               (when (buffer-live-p output)
                 (with-current-buffer output
                   (let ((room (max 0 (- epica-project-search-max-output
                                         (buffer-size)))))
                     (insert (substring chunk 0 (min room (length chunk))))
                     (when (>= (length chunk) room)
                       (setq truncated t)
                       (when (process-live-p process)
                         (delete-process process)))))))
             (settled (process _event)
               (when (memq (process-status process) '(exit signal))
                 (let ((status (process-exit-status process))
                       (text (if (buffer-live-p output)
                                 (with-current-buffer output (buffer-string))
                               "")))
                   (cond
                    ((and (= status 1) (not truncated))
                     (finish (list :content "No matches.")))
                    ((and (/= status 0) (not truncated))
                     (finish (list :content (format "Search failed (exit %s): %s"
                                                    status (string-trim text))
                                   :error t)))
                    (t
                     (let* ((lines (split-string text "\n" t))
                            (complete (if (and truncated
                                               (not (string-suffix-p "\n" text)))
                                          (butlast lines) lines))
                            (capped (cl-subseq complete
                                               0 (min max (length complete)))))
                       (finish
                        (list :content
                              (format "[%d/%d%s matches%s]\n%s"
                                      (length capped) (length complete)
                                      (if truncated "+" "")
                                      (if truncated "; output capped" "")
                                      (string-join capped "\n"))
                              :details (list :total (length complete)
                                             :truncated truncated
                                             :searcher
                                             (file-name-nondirectory searcher)))))))))))
          (condition-case err
              (progn
                (setq proc (make-process
                            :name "epica-project-search" :buffer output
                            :command command :noquery t :filter #'collect
                            :sentinel #'settled))
                (unless done
                  (setq timer
                        (run-at-time epica-project-search-timeout nil
                                     (lambda ()
                                       (finish (list :content "Project search timed out"
                                                     :error t))
                                       (when (process-live-p proc)
                                         (delete-process proc)))))))
            (error (finish (list :content (format "Search error: %S" err)
                                 :error t))))))))))

(define-epica-async-tool project-search
  ((pattern string "Regexp to search for.")
   (max_results integer "Max matches to return (default 50)." :optional t))
  "Search project files without blocking Emacs, returning file:line:content.
Uses ripgrep if available (respects .gitignore), otherwise grep."
  (epica-project--search-async pattern max_results callback))

(define-epica-tool find-file
  ((path string "File path — relative to the project root, or absolute."))
  "Open a file into a buffer (without displaying it).
After opening, use read-buffer to read its contents or edit-region to
modify it. Uses find-file-noselect — the same mechanism as C-x C-f."
  (let* ((proj (project-current))
         (full (if (and proj (not (file-name-absolute-p path)))
                  (expand-file-name path (project-root proj))
                (expand-file-name path))))
    (if (not (file-exists-p full))
        (list :content (format "File not found: %s" full) :error t)
      (let ((buf (find-file-noselect full)))
        (list :content
              (format "Opened %s into buffer %s (%d chars, %d lines)"
                      full (buffer-name buf) (buffer-size buf)
                      (with-current-buffer buf (line-number-at-pos (point-max))))
              :details (list :buffer (buffer-name buf) :path full))))))


;;; -------------------------------------------------- vc tools ----------

(defun epica-project--vc-command (args)
  "Run ARGS with Git in this project, returning stdout on success.
Signal an error with the command output if the VCS exits nonzero."
  (let* ((default-directory
          (or (and (project-current) (project-root (project-current)))
              default-directory))
         (backend (vc-responsible-backend default-directory))
         (exe (executable-find
               (pcase backend
                 ('Git "git")
                 (_ (error "Git-only VC tools; current backend: %S" backend))))))
    (unless exe (error "VCS executable for %s not found" backend))
    (with-temp-buffer
      (let ((status (apply #'call-process exe nil (current-buffer) nil args))
            (output nil))
        (setq output (buffer-string))
        (unless (eq status 0)
          (error "%s %s failed (exit %s): %s"
                 exe (string-join args " ") status (string-trim output)))
        output))))

(define-epica-tool vc-status
  ()
  "Return the Git status of the current project.
Shows modified, staged, and untracked files."
  (condition-case err
      (let ((output (epica-project--vc-command '("status" "--short"))))
        (list :content
              (if (string-empty-p (string-trim output))
                  "Working tree clean — no changes."
                output)))
    (error
     (list :content (format "vc-status error: %S" err) :error t))))

(define-epica-tool vc-diff
  ((since string "Optional: diff since this ref (e.g. 'HEAD~3', 'main'). Default: unstaged changes." :optional t))
  "Return the VCS diff of the current project.
With SINCE, diff against that commit. Without it, show unstaged changes."
  (condition-case err
      (let* ((args (if (and since (not (string-empty-p since)))
                       `("diff" ,since)
                     '("diff")))
             (output (epica-project--vc-command args)))
        (list :content
              (if (string-empty-p (string-trim output))
                  "No changes."
                (substring output 0 (min 8000 (length output))))
              :details (list :since (or since "unstaged")
                             :chars (length output))))
    (error
     (list :content (format "vc-diff error: %S" err) :error t))))

(define-epica-tool vc-log
  ((count integer "Number of recent commits (default 10)." :optional t))
  "Return recent commit history of the current project."
  (condition-case err
      (let ((n (or count 10)))
        (list :content
              (epica-project--vc-command `("log" ,(format "-%d" n) "--oneline"))))
    (error
     (list :content (format "vc-log error: %S" err) :error t))))

(define-epica-tool vc-commit
  ((message string "Commit message.")
   (files string "Optional: comma-separated paths to stage. Default: stage all." :optional t))
  "Stage files and commit with MESSAGE.
FILES (optional, comma-separated) limits what gets staged; omit to stage
all changes (git add -A). The commit message is passed as a single
argument — safe with quotes and special characters."
  (condition-case err
      (progn
        (if (and files (not (string-empty-p files)))
            (epica-project--vc-command
             (append '("add") (split-string files "," t "[ ]+")))
          (epica-project--vc-command '("add" "-A")))
        (epica-project--vc-command `("commit" "-m" ,message))
        (list :content (format "Committed: %s" message)))
    (error
     (list :content (format "VCS commit failed: %S" err) :error t))))

(provide 'epica-project)
;;; epica-project.el ends here
