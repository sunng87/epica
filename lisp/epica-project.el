;;; epica-project.el --- project.el + vc.el tools for epica -*- lexical-binding: t; -*-

;; Project and version-control awareness for epica, built entirely on
;; Emacs' own project.el and vc.el. This is also a TEMPLATE for how to
;; extend epica: (require 'epica) + define-epica-tool + add-hook.
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
(require 'project)
(require 'vc)


;;; -------------------------------------------------- context -----------

(defun epica-project--context ()
  "Inject project context into the system prompt.
Returns a string for `epica-before-agent-start-hook'."
  (when-let ((proj (project-current)))
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
  (if-let ((proj (project-current)))
      (list :content (project-root proj))
    (list :content "Not in a project." :error t)))

(define-epica-tool project-files
  ((pattern string "Optional substring to filter filenames (e.g. '*.py' or 'test')." :optional t)
   (max_results integer "Max files to return (default 50)." :optional t))
  "List files in the current project (relative paths).
Uses project.el's file discovery, which respects .gitignore and project
ignores — the same list C-x p f searches."
  (if-let ((proj (project-current)))
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

(define-epica-tool project-search
  ((pattern string "Regexp to search for.")
   (max_results integer "Max matches to return (default 50)." :optional t))
  "Search the current project for PATTERN. Returns file:line:content.
Uses ripgrep if available (respects .gitignore, fast); falls back to
grep. This is the project-wide equivalent of C-u M-s o."
  (if-let ((proj (project-current)))
      (let* ((root (project-root proj))
             (rg (executable-find "rg"))
             (grep (executable-find "grep"))
             (searcher (or rg grep))
             (max (or max_results 50)))
        (if (null searcher)
            (list :content "No search tool found (install ripgrep or grep)." :error t)
          (let ((output
                 (with-temp-buffer
                   (apply #'call-process searcher nil (current-buffer) nil
                          (if rg
                              `("--no-heading" "-n" "--color=never"
                                "--max-count" "100" ,pattern ,root)
                            `("-rnI" "--exclude-dir=.git" "--color=never"
                              ,pattern ,root)))
                   (buffer-string))))
            (if (string-empty-p (string-trim output))
                (list :content "No matches.")
              (let* ((lines (split-string output "\n" t))
                     (capped (cl-subseq lines 0 (min max (length lines)))))
                (list :content
                      (format "[%d/%d matches]\n%s"
                              (length capped) (length lines)
                              (mapconcat #'identity capped "\n"))
                      :details (list :total (length lines)
                                     :searcher (file-name-nondirectory searcher))))))))
    (list :content "Not in a project." :error t)))

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
  "Run a VCS command (git/hg) in the project root; return stdout."
  (let ((default-directory
         (or (and (project-current) (project-root (project-current)))
             default-directory))
        (exe (or (executable-find "git") (executable-find "hg"))))
    (if (null exe)
        (error "No VCS executable found")
      (with-temp-buffer
        (apply #'call-process exe nil (current-buffer) nil args)
        (buffer-string)))))

(define-epica-tool vc-status
  ()
  "Return the VCS status of the current project (git/hg).
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
  ;; stage
  (condition-case err
      (if (and files (not (string-empty-p files)))
          (epica-project--vc-command
           (append '("add") (split-string files "," t "[ ]+")))
        (epica-project--vc-command '("add" "-A")))
    (error
     (list :content (format "stage error: %S" err) :error t)))
  ;; commit
  (condition-case err
      (progn
        (epica-project--vc-command `("commit" "-m" ,message))
        (list :content (format "Committed: %s" message)))
    (error
     (list :content (format "commit error: %S" err) :error t))))

(provide 'epica-project)
;;; epica-project.el ends here
