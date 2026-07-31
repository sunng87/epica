;;; epica-tools.el --- epica's buffer-native tools          -*- lexical-binding: t; -*-

;; Author: nsun
;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1") (epica) (eshell))
;; Keywords: ai tools convenience

;; The four tools that make epica emacs-native rather than "another file
;; agent": they operate on LIVE buffers, ride buffer-undo-list for free
;; undo, and (eshell) carry real state across calls.
;;
;; Requiring this file defines and registers the tools into `epica-tools'.
;; `epica.el' itself stays lean; load this when you want the coding tools.

;;; Code:

(require 'epica)
(require 'cl-lib)
(require 'subr-x)


;;; -------------------------------------------------- shared helpers ----

(defun epica--truthy (v)
  "Coerce a JSON-boolean-ish value V to a Lisp boolean.
gptel hands tool-call booleans as t or :json-false; normalise."
  (and v (not (eq v :json-false))))

(defun epica--resolve-buffer (name)
  "Resolve NAME to a live buffer: exact match, then substring match.
Returns the buffer, or nil."
  (when (stringp name)
    (let* ((all (mapcar #'buffer-name (buffer-list)))
           (bn (or (car (member name all))
                   (cl-find-if
                    (lambda (b) (string-match-p (regexp-quote name) b))
                    all))))
      (and bn (get-buffer bn)))))

(defun epica--buffer-head (buf &optional chars)
  "Return the first CHARS (default 400) of BUF, for error guidance."
  (with-current-buffer buf
    (let ((end (min (or chars 400) (- (point-max) (point-min)))))
      (buffer-substring-no-properties (point-min) (+ (point-min) end)))))

(defun epica--live-buffers ()
  "Human-readable list of live buffer names, for error guidance."
  (mapcar #'buffer-name (buffer-list)))


;;; -------------------------------------------------- read-buffer -------

(define-epica-tool read-buffer
  ((name string "Buffer name to read (exact, or a substring that uniquely matches a live buffer).")
   (offset integer "1-based line number to start reading from (optional)." :optional t)
   (limit integer "Maximum number of lines to return (optional)." :optional t)
   (show_line_numbers boolean "If true, prefix each returned line with its number." :optional t))
  "Read the contents of a live Emacs buffer.

Returns the buffer text (optionally a line slice, optionally numbered),
prefixed with the buffer name and line count. If the buffer is narrowed,
only the narrowed region is read -- narrowing is epica's native 'show the
model part of the buffer' mechanism.

Lenient on the buffer name: an exact match is tried first, then a
substring match against all live buffers. On failure, lists live buffers
so the caller can self-correct."
  (if-let ((buf (epica--resolve-buffer name)))
      (with-current-buffer buf
        (let* ((narrowed (buffer-narrowed-p))
               (lines (split-string
                       (buffer-substring-no-properties (point-min) (point-max))
                       "\n"))
               (total (length lines))
               (start-idx (if (and (integerp offset) (> offset 0)) (1- offset) 0))
               (end-idx (if (and (integerp limit) (> limit 0))
                            (min total (+ start-idx limit))
                          total))
               (slice (cl-subseq lines (max 0 start-idx) (max (max 0 start-idx) end-idx)))
               (numbered (if (epica--truthy show_line_numbers)
                             (cl-loop for l in slice
                                      for i from (1+ (max 0 start-idx))
                                      collect (format "%5d\t%s" i l))
                           slice))
               (text (string-join numbered "\n")))
          (list :content
                (format "[buffer %s — %d lines%s]\n%s"
                        (buffer-name buf) total
                        (if narrowed " (NARROWED)" "")
                        text))))
    (list :content
          (format "No buffer matching %S. Live buffers: %S" name (epica--live-buffers))
          :error t)))


;;; -------------------------------------------------- edit-region -------

;; The headline tool. The model gives old_text (must be unique) and
;; new_text; we locate it, delete+insert -- which pushes onto
;; buffer-undo-list, so undo is free (C-/ or undo-tree). Markers keep the
;; locate/apply robust against any drift. Non-unique or missing old_text
;; returns a helpful error so the model can self-correct.

(define-epica-tool edit-region
  ((buffer string "Buffer to edit (exact or substring match).")
   (old_text string "Exact text to find and replace. Must occur exactly once in the buffer.")
   (new_text string "The replacement text."))
  "Replace the unique occurrence of old_text with new_text in a live buffer.

This is epica's primary edit tool. The edit is applied to the LIVE buffer
(not a file on disk), so the user sees it immediately, and it rides on
buffer-undo-list -- the user can undo it with \\[undo] (or undo-tree) for free.

Requirements: old_text must match EXACTLY (whitespace and indentation
count) and must be UNIQUE in the buffer. If it is missing or appears more
than once, the tool returns an error describing the problem so you can
retry with more surrounding context. Make old_text as small as possible
while still being unique."
  (let ((old (or old_text "")))
    (cond
     ((string-empty-p old)
      (list :content "old_text is empty; nothing to find." :error t))
     ((not (epica--resolve-buffer buffer))
      (list :content
            (format "No buffer matching %S. Live buffers: %S"
                    buffer (epica--live-buffers))
            :error t))
     (t
      (with-current-buffer (epica--resolve-buffer buffer)
        (save-excursion
          (save-restriction
            (widen)  ; search the whole buffer regardless of narrowing
            (goto-char (point-min))
            (cond
             ((not (search-forward old nil t))
              (list :content
                    (format "old_text not found in %s. First 400 chars:\n%s"
                            (buffer-name) (epica--buffer-head (current-buffer)))
                    :error t))
             (t
              (let ((mstart (copy-marker (match-beginning 0)))
                    (mend (copy-marker (match-end 0))))
                ;; uniqueness check: another occurrence after the first?
                (if (search-forward old nil t)
                    (list :content
                          (format "old_text is not unique in %s -- it appears at least twice. "
                                  (buffer-name))
                          :error t)
                  ;; apply: delete between markers, insert new text.
                  ;; delete-region+insert both push onto buffer-undo-list.
                  (goto-char mstart)
                  (delete-region mstart mend)
                  (insert new_text)
                  (let ((line-start (line-number-at-pos mstart))
                        (line-end (line-number-at-pos (point))))
                    (list :content
                          (format "Edited %s: replaced %d chars with %d chars "
                                  (buffer-name) (length old) (length new_text))
                          :details (list :buffer (buffer-name)
                                         :line-start line-start
                                         :line-end line-end
                                         :undoable t))))))))))))))


;;; -------------------------------------------------- write-buffer ------

(define-epica-tool write-buffer
  ((buffer string "Buffer name to write. Created if it does not exist.")
   (content string "The full new contents of the buffer.")
   (file_path string "Optional: also write these contents to this file path on disk." :optional t))
  "Create or overwrite a live Emacs buffer with CONTENT.

The buffer is erased and filled with CONTENT (undoable via
buffer-undo-list). If FILE_PATH is given, the contents are additionally
written to that file with `write-region' (the buffer is not reassociated
with the file). Use this to create new buffers/files or to do a full
replacement where edit-region's find-and-replace is awkward."
  (let ((buf (get-buffer-create buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert content)
        (when (and file_path (stringp file_path) (not (string-empty-p file_path)))
          (write-region (point-min) (point-max) file_path))))
    (list :content
          (format "Wrote %d chars to buffer %s%s"
                  (length content) buffer
                  (if (and file_path (not (string-empty-p file_path)))
                      (format " (and file %s)" file_path)
                    ""))
          :details (list :buffer buffer :chars (length content)
                         :file file_path))))


;;; -------------------------------------------------- shell-run --------

;; A persistent shell process (bash via make-comint). cwd and env
;; survive across calls -- the differentiator vs pi's stateless
;; per-call bash. We use make-comint rather than a literal eshell
;; session because make-comint works identically headless (batch, CI)
;; and interactive; eshell's process will not start under --batch.
;; elisp-via-eshell interop is a future option, not needed for v1.

(defcustom epica-shell-buffer-name "*epica-shell*"
  "Name of epica's persistent shell process buffer."
  :type 'string :group 'epica)

(defcustom epica-shell-default-timeout 30
  "Default seconds to wait for a shell command before giving up."
  :type 'integer :group 'epica)

(defcustom epica-shell-program
  (or (executable-find "bash") (getenv "SHELL") "/bin/sh")
  "Shell program epica's persistent session runs.
Defaults to bash (reliable flags across the board), not $SHELL."
  :type 'string :group 'epica)

(defvar epica--shell-buffer nil
  "Cached persistent shell buffer.")

(defun epica--shell-session ()
  "Return epica's persistent shell buffer, starting the process once.
The buffer is created with `make-comint' so it works headless. Returns
the buffer, or errors if the process cannot be started."
  (if (and (buffer-live-p epica--shell-buffer)
           (get-buffer-process epica--shell-buffer))
      epica--shell-buffer
    (let ((buf (make-comint "epica-shell" epica-shell-program nil)))
      (setq epica--shell-buffer buf)
      (let ((proc (get-buffer-process buf))
            (deadline (+ (float-time) 3)))
        (while (and proc (memq (process-status proc) '(open run))
                    (< (float-time) deadline))
          (accept-process-output proc 0.1)))
      (or (get-buffer-process buf)
          (error "epica: could not start persistent shell (%s)" epica-shell-program))
      buf)))

(defun epica--shell-send-and-capture (command timeout)
  "Run COMMAND in the persistent shell; return (OUTPUT . EXIT-CODE).
Sentinel-delimited capture for clean output and a recoverable exit code.
TIMEOUT bounds the wait in seconds."
  (let* ((buf (epica--shell-session))
         (proc (get-buffer-process buf))
         (id (format "%06d" (random 1000000)))
         (start-tag (format "__EPICA_START_%s__" id))
         (end-tag (format "__EPICA_END_%s__" id))
         (deadline (+ (float-time) (or timeout epica-shell-default-timeout)))
         output exit-code)
    (with-current-buffer buf
      (let ((scan-from (point-max)))
        (goto-char (point-max))
        (process-send-string
         proc
         (format "echo %s; %s; echo %s$?\n" start-tag command end-tag))
        (while (and (process-live-p proc)
                    (progn (goto-char scan-from)
                           (not (re-search-forward
                                 (concat (regexp-quote end-tag) "\\([0-9]+\\)")
                                 nil t)))
                    (< (float-time) deadline))
          (accept-process-output proc 0.1))
        (goto-char scan-from)
        (if (re-search-forward
             (concat (regexp-quote start-tag) "\n\\(\\(?:.\\|\n\\)*?\\)"
                     (regexp-quote end-tag) "\\([0-9]+\\)")
             nil t)
            (setq output (match-string 1)
                  exit-code (string-to-number (match-string 2)))
          (setq output (buffer-substring-no-properties scan-from (point-max))
                exit-code -1))))
    (cons (or output "") (or exit-code -1))))

(define-epica-tool shell-run
  ((command string "Shell command to run.")
   (timeout integer "Seconds to wait for completion (default 30)." :optional t))
  "Run COMMAND in epica's persistent shell session.

State is preserved across calls: working directory (cd), environment
variables (export), and shell functions all survive from one call to the
next -- unlike tools that spawn a fresh shell each time. Output
(stdout+stderr) and the exit code are returned. If the command does not
finish within TIMEOUT seconds, partial output is returned with exit
code -1."
  (condition-case err
      (let* ((wait (if (and (integerp timeout) (> timeout 0))
                       timeout epica-shell-default-timeout))
             (res (epica--shell-send-and-capture command wait))
             (out (car res))
             (code (cdr res)))
        (list :content
              (format "[exit %d]\n%s" code (or out ""))
              :details (list :exit code :command command)))
    (error
     (list :content (format "shell error: %S" err) :error t))))


;;; -------------------------------------------------- skills -----------

(define-epica-tool load-skill
  ((name string "Name of the skill to load (from the available skills list in the system prompt)."))
  "Load an Agent Skills skill (SKILL.md) by NAME and return its full
instructions, plus the list of files in the skill directory.

The system prompt lists available skills with one-line descriptions.
Call this tool when a task matches a listed skill's description before
improvising. Skills follow the cross-ecosystem Agent Skills standard, so
they work identically in epica, pi, and other harnesses."
  (epica-skill-load name))

(provide 'epica-tools)
;;; epica-tools.el ends here
