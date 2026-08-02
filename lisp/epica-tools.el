;;; epica-tools.el --- epica's buffer-native tools          -*- lexical-binding: t; -*-

;; Author: nsun
;; Version: 0.0.1
;; Keywords: ai tools convenience
;;
;; NOTE: no Package-Requires header here on purpose. Only the main file
;; (epica.el) declares package requirements; package-vc merges headers
;; from EVERY .el in the package, and a self-reference ((epica) here)
;; would make the merged description require itself -> infinite
;; activation recursion. Runtime requires are plain `require' forms.

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
(require 'eshell)   ; eshell-run backend; must load before binding eshell-buffer-name


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
          (write-region (point-min) (point-max) file_path)
          ;; If this buffer VISITS the file we just wrote, sync the
          ;; recorded modtime and clear the modified flag. A bare
          ;; write-region leaves both stale, so the next save-buffer
          ;; would prompt "file changed on disk" even though the file
          ;; content matches the buffer exactly.
          (when (and buffer-file-name
                     (file-equal-p (file-truename buffer-file-name)
                                   (file-truename file_path)))
            (set-visited-file-modtime)
            (set-buffer-modified-p nil)))))
    (list :content
          (format "Wrote %d chars to buffer %s%s"
                  (length content) buffer
                  (if (and file_path (not (string-empty-p file_path)))
                      (format " (and file %s)" file_path)
                    ""))
          :details (list :buffer buffer :chars (length content)
                         :file file_path))))


;;; -------------------------------------------------- eshell-run --------

;; The agent's shell IS Emacs' shell. Each epica session owns an eshell
;; buffer (buffer-local, named after the session), so cwd/env/state
;; persist per session and never leak across sessions. Commands run
;; through eshell's own evaluation: every command or elisp expression
;; has a return VALUE plus whatever it printed.
;;
;; Two execution paths:
;;  - process-backed (interactive/daemon Emacs): the session's eshell
;;    has a live process; we send input, wait for the prompt, and read
;;    the value and the printed output. Fully stateful.
;;  - no-process fallback (batch): eshell cannot attach a persistent
;;    process under --batch, so we evaluate with `eshell-command-result'
;;    (same value semantics, but stateless across calls).

(defcustom epica-eshell-default-timeout 30
  "Default seconds to wait for an eshell command before giving up."
  :type 'integer :group 'epica)

(defvar-local epica--eshell-buffer nil
  "Eshell buffer owned by the current epica session (nil until first use).")

(defun epica--eshell-session-buffer ()
  "Return (creating if needed) the eshell buffer for this session.
The eshell buffer is named after the session buffer, so each session
gets its own shell with its own state."
  (or epica--eshell-buffer
      (let ((name (format "*epica-eshell: %s*" (buffer-name))))
        (unless (get-buffer name)
          ;; (eshell t) creates the buffer and, interactively, its process
          (let ((eshell-buffer-name name))
            (save-window-excursion (eshell t))))
        (setq-local epica--eshell-buffer (get-buffer name))
        epica--eshell-buffer)))

(defun epica--eshell-wait-idle (baseline timeout)
  "Pump until eshell output is stable and no process is running.
BASELINE is the buffer size BEFORE the command was sent (so commands
that finish synchronously are detected). Returns non-nil if the command
finished; nil on timeout."
  (let ((deadline (+ (float-time) (or timeout epica-eshell-default-timeout)))
        (prev baseline) (stable 0) (started nil) finished)
    (while (and (not finished) (< (float-time) deadline))
      (accept-process-output nil 0.1)
      (let ((size (point-max)))
        (cond
         ((> size prev)
          (setq started t stable 0))       ; output still arriving
         ((and started (not (eshell-head-process)))
          (setq stable (1+ stable))
          (when (>= stable 3) (setq finished t)))  ; 0.3s of quiet
         (t (setq stable 0))))
      (setq prev (point-max)))
    finished))

(defun epica--eshell-run-live (command timeout)
  "Stateful eshell execution in this session's eshell buffer.
Sends COMMAND via `eshell-send-input' and pumps until the output
settles; returns (VALUE OUTPUT STATUS). State (cwd, env) persists in
the eshell buffer across calls."
  (let* ((buf (epica--eshell-session-buffer))
         (sentinel (make-symbol "epica--unset"))
         value output status)
    (with-current-buffer buf
      (let ((output-start (point-max)))
        (goto-char (point-max))
        (insert command)
        (setq-local eshell-last-command-result sentinel)
        (let ((baseline (point-max)))
          (eshell-send-input)
          (if (not (epica--eshell-wait-idle baseline timeout))
            (setq status -1
                  value (if (eq eshell-last-command-result sentinel)
                            "(timeout)"
                          (let ((r eshell-last-command-result))
                            (if (stringp r)
                                (substring-no-properties r)
                              (prin1-to-string r))))
                  output (buffer-substring-no-properties
                          (progn (goto-char output-start) (forward-line 1) (point))
                          (point-max)))
          (setq status eshell-last-command-status
                value (if (eq eshell-last-command-result sentinel)
                          "nil"
                        (let ((r eshell-last-command-result))
                          (if (stringp r)
                              (substring-no-properties r)
                            (prin1-to-string r))))
                output
                (string-trim
                 (buffer-substring-no-properties
                  (progn (goto-char output-start)
                         (forward-line 1)   ; skip the command echo
                         (point))
                  (or (progn (goto-char (point-max))
                             (re-search-backward eshell-prompt-regexp nil t)
                             (match-beginning 0))
                      (point-max)))))))))
    (list value output status)))

(defun epica--eshell-run-batch (command)
  "Stateless eshell evaluation for batch mode (eshell cannot run
external commands via send-input without the interactive process
machinery). Evaluates in a clean temp eshell buffer via
`eshell-command-result', which returns command values correctly."
  (with-temp-buffer
    (eshell-mode)
    (let ((result (eshell-command-result command)))
      (list (if (stringp result) result (prin1-to-string result))
            (if (stringp result) result (prin1-to-string result))
            eshell-last-command-status))))

(defun epica--eshell-run (command timeout)
  "Run COMMAND in this session's eshell; return (VALUE OUTPUT STATUS).
Uses the stateful `eshell-send-input' path in daemon/interactive Emacs;
falls back to stateless `eshell-command-result' under `noninteractive'
(batch), where eshell lacks the process machinery."
  (if noninteractive
      (epica--eshell-run-batch command)
    (epica--eshell-run-live command timeout)))

(define-epica-tool eshell-run
  ((command string "Shell command or Emacs Lisp expression to run in this session's eshell.")
   (timeout integer "Seconds to wait for completion (default 30)." :optional t))
  "Run COMMAND in this epica session's persistent eshell.

This is Emacs' own shell: COMMAND may be a shell command or an Emacs
Lisp expression, and every command returns a VALUE -- elisp expressions
return their value, external commands return their output. State
persists per session: cd, setenv/export, and aliases survive across
calls. Returns the return value, the printed output, and the exit
status."
  (condition-case err
      (let* ((res (epica--eshell-run command timeout))
             (value (nth 0 res))
             (output (nth 1 res))
             (status (nth 2 res)))
        (list :content
              (string-join
               (delq nil
                     (list (format "[exit %s]" (or status "?"))
                           (format "value: %s" (or value "(nil)"))
                           (and output (not (string-empty-p output))
                                (unless (equal output value) output))))
               "\n")
              :details (list :value value :output output :status status)))
    (error
     (list :content (format "eshell error: %S" err) :error t))))


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


;;; -------------------------------------------------- webfetch --------

;; Fetching URLs the Emacs way: url.el (built-in HTTP/TLS/redirect/
;; proxy machinery — no curl, no subprocess) + shr (built-in HTML
;; renderer) for readable text. Same network stack Emacs itself uses.

(defcustom epica-webfetch-max-chars 8000
  "Default maximum characters the webfetch tool returns."
  :type 'integer :group 'epica)

(defcustom epica-webfetch-timeout 20
  "Seconds to wait for a webfetch before giving up."
  :type 'integer :group 'epica)

(defun epica--webfetch-text (buffer)
  "Extract readable text from an HTTP response BUFFER.
Returns (CONTENT-TYPE . TEXT). HTML is rendered to text via shr;
binary types are reported, not dumped."
  (with-current-buffer buffer
    (goto-char (point-min))
    (let* ((header-end (if (search-forward "\n\n" nil t) (point) (point-min)))
           (content-type (save-excursion
                           (goto-char (point-min))
                           (when (re-search-forward
                                  "^Content-Type: *\\([^;\r\n]+\\)" nil t)
                             (downcase (string-trim (match-string 1))))))
           (raw (buffer-substring-no-properties header-end (point-max))))
      (cond
       ((and content-type (string-match-p "html" content-type))
        (cons content-type
              (condition-case err
                  (with-temp-buffer
                    (require 'shr)
                    (shr-insert-document
                     (with-temp-buffer
                       (insert raw)
                       (libxml-parse-html-region (point-min) (point-max))))
                    (buffer-string))
                (error (format "(html rendering failed: %S)" err)))))
       ;; binary sniff: NUL bytes = binary regardless of content-type
       ;; (file:// text files come through as octet-stream, so the
       ;; content-type alone would misclassify them)
       ((string-match-p (string ?\0) raw)
        (cons content-type
              (format "[binary content: %d bytes, type %s — not shown]"
                      (length raw) content-type)))
       (t (cons content-type raw))))))

(defun epica--webfetch (url max-chars timeout)
  "Fetch URL; return (TEXT STATUS CONTENT-TYPE).
Uses `url-retrieve-synchronously' with a timeout; HTML is rendered to
text. On failure TEXT explains the error."
  (let ((url-request-extra-headers
         (cons '("User-Agent" . "epica/0.1 (Emacs-native agent)")
               url-request-extra-headers)))
    (condition-case err
        (let ((buf (url-retrieve-synchronously
                    url t nil (or timeout epica-webfetch-timeout))))
          (if (null buf)
              (list (format "fetch failed (error or timeout after %s s)"
                            (or timeout epica-webfetch-timeout))
                    "failed" nil)
            (unwind-protect
                (with-current-buffer buf
                  (goto-char (point-min))
                  (let* ((status (if (re-search-forward
                                      "^HTTP/1\\.[01] \\([0-9]+\\)" nil t)
                                     (match-string 1) "?"))
                         (text (epica--webfetch-text buf))
                         (content (substring-no-properties (cdr text))))
                    (list (substring content 0
                                     (min (or max-chars epica-webfetch-max-chars)
                                          (length content)))
                          status (car text))))
              (kill-buffer buf))))
      (error (list (format "fetch error: %S" err) "error" nil)))))

(define-epica-tool webfetch
  ((url string "The URL to fetch (http://, https://, or file://).")
   (max_chars integer "Maximum characters of text to return (default 8000)." :optional t))
  "Fetch a URL and return its readable text content.

Emacs-native: uses url.el — the same HTTP/TLS/redirect/proxy stack
Emacs itself uses. No curl, no subprocess. HTML pages are rendered to
readable text via shr; binary content (images, PDFs, archives) is
reported with its type and size, not dumped. Use this to read
documentation, APIs, or web pages instead of shelling out to curl."
  (let* ((res (epica--webfetch url max_chars nil))
         (text (nth 0 res)) (status (nth 1 res)) (ct (nth 2 res)))
    (list :content
          (format "[%s] (%s, %d chars)\n%s"
                  (or status "?") (or ct "unknown") (length text) text)
          :details (list :url url :status status :content-type ct
                         :chars (length text)))))

(provide 'epica-tools)
;;; epica-tools.el ends here
