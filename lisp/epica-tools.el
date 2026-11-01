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

;; The built-in tools work on live buffers, preserve Emacs undo/save
;; behavior, and use asynchronous Eshell and url.el operations.
;;
;; Requiring `epica' loads and registers these coding tools.

;;; Code:

(require 'epica)
(require 'cl-lib)
(require 'subr-x)
(require 'eshell)   ; eshell-run backend; must load before binding eshell-buffer-name
(require 'esh-mode) ; eshell-send-input

(defvar eshell-prompt-regexp) ; set by eshell-mode in its session buffer


;;; -------------------------------------------------- shared helpers ----

(defun epica--truthy (v)
  "Coerce a JSON-boolean-ish value V to a Lisp boolean.
gptel hands tool-call booleans as t or :json-false; normalise."
  (and v (not (eq v :json-false))))

(defun epica--resolve-buffer (name)
  "Resolve NAME to a live buffer, rejecting ambiguous substring matches.
Prefer an exact name; return nil if there is no match."
  (when (stringp name)
    (or (get-buffer name)
        (let ((matches (cl-remove-if-not
                        (lambda (buf)
                          (string-match-p (regexp-quote name)
                                          (buffer-name buf)))
                        (buffer-list))))
          (pcase matches
            (`(,only) only)
            (`() nil)
            (_ (user-error "Ambiguous buffer %S; matches: %S"
                           name (mapcar #'buffer-name matches))))))))

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
only the narrowed region is read -- narrowing exposes just the part
of the buffer you want the model to see.

Lenient on the buffer name: an exact match is tried first, then a
substring match against all live buffers. On failure, lists live buffers
so the caller can self-correct."
  (if-let* ((buf (epica--resolve-buffer name)))
      (with-current-buffer buf
        (let* ((narrowed (buffer-narrowed-p))
               (lines (split-string
                       (buffer-substring-no-properties (point-min) (point-max))
                       "\n"))
               (total (length lines))
               (start-idx (min total
                               (if (and (integerp offset) (> offset 0))
                                   (1- offset) 0)))
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


;;; -------------------------------------------------- open/save-buffer --

(define-epica-tool open-file
  ((path string "File to open, absolute or relative to this session's project directory."))
  "Visit an existing file in an Emacs buffer without displaying it.

This is how to access source files that are not already open. An
existing visiting buffer (including unsaved edits) is reused, never
reverted or replaced. Use read-buffer and edit-region on its returned
buffer name; use save-buffer to persist edits after review."
  (let ((file (expand-file-name path)))
    (if (not (file-regular-p file))
        (list :content (format "File not found: %s" file) :error t)
      (let ((buf (find-file-noselect file)))
        (list :content (format "Opened %s in buffer %s%s"
                               file (buffer-name buf)
                               (if (buffer-modified-p buf) " (unsaved edits)" ""))
              :details (list :buffer (buffer-name buf) :file file))))))

(define-epica-tool save-buffer
  ((name string "Name of a file-visiting buffer to save (exact or unique substring)."))
  "Save a live file-visiting buffer through Emacs, preserving save hooks.
Never writes around the buffer or silently discards unsaved edits."
  (if-let* ((buf (epica--resolve-buffer name)))
      (with-current-buffer buf
        (if (not buffer-file-name)
            (list :content (format "Buffer %s does not visit a file" (buffer-name))
                  :error t)
          (save-buffer)
          (list :content (format "Saved %s from buffer %s"
                                 buffer-file-name (buffer-name)))))
    (list :content
          (format "No buffer matching %S. Live buffers: %S"
                  name (epica--live-buffers))
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
          (let ((case-fold-search nil))
            ;; Honor narrowing: the visible region is the agent's scope.
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
                ;; Search from one character past the first start so
                ;; overlapping matches are not mistaken for uniqueness.
                (if (save-excursion
                      (goto-char (1+ mstart))
                      (search-forward old nil t))
                    (list :content
                          (format "old_text is not unique in %s -- it appears at least twice. "
                                  (buffer-name))
                          :error t)
                  ;; Group the deletion and insertion into one undo step.
                  (undo-boundary)
                  (atomic-change-group
                    (goto-char mstart)
                    (delete-region mstart mend)
                    (insert new_text))
                  (undo-boundary)
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
  "Replace a live buffer with CONTENT, optionally saving FILE_PATH.
When FILE_PATH is given, edit its file-visiting buffer, never write
around another buffer visiting that file. Refuse to overwrite unsaved
user changes in a file-visiting buffer; use edit-region for those."
  (let* ((file (and (stringp file_path) (not (string-empty-p file_path))
                    (expand-file-name file_path)))
         (visiting (and file (find-buffer-visiting file)))
         (buf (if file
                  (or visiting (find-file-noselect file))
                (get-buffer-create buffer))))
    (with-current-buffer buf
      (when (and buffer-file-name (file-exists-p buffer-file-name)
                 (buffer-modified-p))
        (user-error "Refusing to overwrite unsaved changes in %s; use edit-region"
                    (buffer-name buf)))
      (atomic-change-group
        (erase-buffer)
        (insert content))
      (when file (save-buffer)))
    (list :content
          (format "Wrote %d chars to buffer %s%s"
                  (length content) (buffer-name buf)
                  (if file (format " (and file %s)" file) ""))
          :details (list :buffer (buffer-name buf) :chars (length content)
                         :file file))))


;;; -------------------------------------------------- eshell-run --------

;; The agent's shell IS Emacs' shell. Each epica session owns an eshell
;; buffer (buffer-local, named after the session), so cwd/env/state
;; persist per session and never leak across sessions. Commands run
;; through eshell's own evaluation: every command or elisp expression
;; has a return VALUE plus whatever it printed.
;;
;; Interactive/daemon Emacs dispatches through the Eshell prompt hook,
;; completing the async tool only after the prompt returns. Under --batch,
;; Eshell has no interactive process machinery, so the fallback uses
;; `eshell-command-result' (stateless, for tests and batch scripts).

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

(defun epica--eshell-run (command _timeout)
  "Batch-only Eshell helper for older tests; return (VALUE OUTPUT STATUS).
In interactive Emacs, use `epica--eshell-run-async' instead so the
agent does not freeze redisplay."
  (if noninteractive
      (epica--eshell-run-batch command)
    (error "Use asynchronous Eshell in interactive Emacs")))

(defvar-local epica--eshell-busy nil
  "Non-nil while an epica command owns this Eshell buffer.")

(defun epica--eshell-result (value output status)
  "Format the Eshell VALUE, OUTPUT and STATUS for the agent."
  (list :content
        (string-join
         (delq nil
               (list (format "[exit %s]" (or status "?"))
                     (format "value: %s" (or value "(nil)"))
                     (and output (not (string-empty-p output))
                          (unless (equal output value) output))))
         "\n")
        :details (list :value value :output output :status status)))

(defun epica--eshell-run-async (command timeout callback)
  "Run COMMAND in this session's Eshell, then invoke CALLBACK.
Interactive Emacs uses `eshell-after-prompt-hook' rather than polling;
batch Emacs uses the stateless Eshell command-result fallback."
  (if noninteractive
      (pcase-let ((`(,value ,output ,status) (epica--eshell-run-batch command)))
        (funcall callback (epica--eshell-result value output status)))
    (let ((buf (epica--eshell-session-buffer))
          (deadline (if (and (numberp timeout) (> timeout 0))
                        timeout epica-eshell-default-timeout)))
      (with-current-buffer buf
        (when (or epica--eshell-busy (eshell-head-process))
          (user-error "Eshell is busy; wait for the previous command"))
        (let ((start (point-max-marker)) (timer nil) (done nil)
              (sentinel (make-symbol "epica--unset")))
          (cl-labels
              ((finish (timed-out)
                 (unless done
                   (setq done t)
                   (when timer (cancel-timer timer))
                   (when (buffer-live-p buf)
                     (with-current-buffer buf
                       (remove-hook 'eshell-after-prompt-hook #'prompt-finished t)
                       (setq epica--eshell-busy nil)
                       (let* ((value (if (eq eshell-last-command-result sentinel)
                                         (if timed-out "(timeout)" "nil")
                                       (let ((r eshell-last-command-result))
                                         (if (stringp r)
                                             (substring-no-properties r)
                                           (prin1-to-string r)))))
                              (end (or (save-excursion
                                         (goto-char (point-max))
                                         (when (re-search-backward
                                                eshell-prompt-regexp start t)
                                           (match-beginning 0)))
                                       (point-max)))
                              (output (save-excursion
                                        (goto-char start)
                                        (forward-line 1)
                                        (string-trim
                                         (buffer-substring-no-properties
                                          (min (point) end) end))))
                              (status (if timed-out -1 eshell-last-command-status)))
                         (set-marker start nil)
                         (when (and timed-out (eshell-head-process))
                           (interrupt-process (eshell-head-process)))
                         (funcall callback
                                  (epica--eshell-result value output status)))))))
               (prompt-finished () (finish nil)))
            (setq epica--eshell-busy t
                  eshell-last-command-result sentinel)
            (add-hook 'eshell-after-prompt-hook #'prompt-finished nil t)
            (setq timer (run-at-time deadline nil (lambda () (finish t))))
            (goto-char (point-max))
            (insert command)
            (condition-case err
                (eshell-send-input)
              (error
               (finish t)
               (signal (car err) (cdr err))))))))))

(defun epica--eshell-close-session ()
  "Kill this session's Eshell when the session shuts down."
  (when (buffer-live-p epica--eshell-buffer)
    (kill-buffer epica--eshell-buffer))
  (setq epica--eshell-buffer nil))

(add-hook 'epica-session-shutdown-hook #'epica--eshell-close-session)

(define-epica-async-tool eshell-run
  ((command string "Shell command or Emacs Lisp expression to run in this session's eshell.")
   (timeout integer "Seconds before reporting timeout (default 30)." :optional t))
  "Run COMMAND in this session's persistent Eshell without freezing Emacs.
The value, printed output and exit status are returned when Eshell
emits the next prompt. A busy session cannot run overlapping commands."
  (epica--eshell-run-async command timeout callback))


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
    (let* ((header-end (if (re-search-forward "\r?\n\r?\n" nil t)
                           (point) (point-min)))
           (content-type (save-excursion
                           (let ((case-fold-search t))
                             (goto-char (point-min))
                             (when (re-search-forward
                                    "^Content-Type: *\\([^;\r\n]+\\)" nil t)
                               (downcase (string-trim (match-string 1)))))))
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

(defun epica--webfetch-async (url max-chars timeout callback)
  "Retrieve URL without blocking redisplay, passing its result to CALLBACK.
MAX-CHARS bounds returned text. TIMEOUT bounds the request in seconds.
A timeout releases the URL buffer/process and invokes CALLBACK once."
  (let ((request-buffer nil)
        (timer nil)
        (done nil)
        (limit (if (and (integerp max-chars) (>= max-chars 0))
                   max-chars epica-webfetch-max-chars))
        (deadline (if (and (numberp timeout) (> timeout 0))
                      timeout epica-webfetch-timeout))
        (url-request-extra-headers
         (cons '("User-Agent" . "epica/0.1 (Emacs-native agent)")
               url-request-extra-headers)))
    (cl-labels
        ((complete (result)
           (unless done
             (setq done t)
             (when timer (cancel-timer timer))
             (when (buffer-live-p request-buffer)
               (when-let* ((proc (get-buffer-process request-buffer)))
                 (delete-process proc))
               (kill-buffer request-buffer))
             (funcall callback result)))
         (received (status)
           (let ((buf (current-buffer)))
             (condition-case err
                 (if (plist-get status :error)
                     (complete (list :content (format "fetch failed: %S"
                                                      (plist-get status :error))
                                     :error t))
                   (goto-char (point-min))
                   (let* ((http (if (re-search-forward
                                     "^HTTP/[0-9.]+ \\([0-9]+\\)" nil t)
                                    (match-string 1) "local"))
                          (parsed (epica--webfetch-text buf))
                          (text (cdr parsed))
                          (body (substring text 0 (min limit (length text)))))
                     (complete
                      (list :content
                            (format "[%s] (%s, %d chars)\n%s"
                                    http (or (car parsed) "unknown")
                                    (length body) body)
                            :details (list :url url :status http
                                           :content-type (car parsed)
                                           :chars (length body))))))
               (error (complete (list :content (format "fetch error: %S" err)
                                      :error t))))
             (when (buffer-live-p buf) (kill-buffer buf)))))
      (setq timer (run-at-time
                   deadline nil
                   (lambda ()
                     (complete (list :content (format "fetch timed out after %ss"
                                                      deadline)
                                     :error t)))))
      (condition-case err
          (progn
            (setq request-buffer (url-retrieve url #'received nil t))
            (unless request-buffer
              (complete (list :content "fetch failed: no response buffer"
                              :error t))))
        (error (complete (list :content (format "fetch error: %S" err)
                               :error t)))))))

(define-epica-async-tool webfetch
  ((url string "The URL to fetch (http://, https://, or file://).")
   (max_chars integer "Maximum characters of text to return (default 8000)." :optional t))
  "Fetch a URL asynchronously using Emacs url.el; render HTML through shr.
The editor stays responsive while the request runs, and timed-out
requests report an error instead of hanging the agent."
  (epica--webfetch-async url max_chars nil callback))

(provide 'epica-tools)
;;; epica-tools.el ends here
