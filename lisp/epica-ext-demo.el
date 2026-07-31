;;; epica-ext-demo.el --- example epica extension: gates + redaction -*- lexical-binding: t; -*-

;; A MODEL for user extensions. epica needs no plugin loader: an
;; extension is just an Emacs file that adds to epica's hooks. This file
;; is meant to be copy-pasted/adapted, not installed as-is.
;;
;; It demonstrates three extension points:
;;   1. `epica-tool-call-hook'   -- BLOCK dangerous shell commands
;;   2. `epica-tool-result-hook' -- REWRITE tool results (redact secrets)
;;   3. `epica-before-agent-start-hook' -- append to the system prompt
;;
;; Load it with (require 'epica-ext-demo).

;;; Code:

(require 'epica)

(defvar epica-ext-blocked-commands '()
  "Log of commands blocked by the demo gate: (TIME . COMMAND).")

(defvar epica-ext-redacted-results '()
  "Log of results redacted by the demo hook: (TIME . RESULT).")

(defcustom epica-ext-destructive-patterns
  ;; note: models try to bypass gates (find -delete, unlink, ...) —
  ;; cover the common deletion verbs, not just rm
  '("\\brm\\b" "\\bsudo\\b" "\\bmkfs\\b" "\\bshred\\b"
    "\\bunlink\\b" "\\brmdir\\b" "\\btruncate\\b"
    "\\bfind\\b.*\\b-delete\\b" "\\bdd if=")
  "Regexes that mark a shell-run command as destructive."
  :type '(repeat regexp) :group 'epica)

(defcustom epica-ext-secret-patterns
  '("TOPSECRET[A-Z0-9]*" "sk-[A-Za-z0-9_-]\\{20,\\}")
  "Regexes redacted from tool results before the model sees them."
  :type '(repeat regexp) :group 'epica)

(defun epica-ext--gate-shell (info)
  "Block destructive commands in the shell-run tool.
Returns (block . REASON) when the command matches a destructive pattern."
  (when (equal (plist-get info :name) "shell-run")
    (let ((cmd (plist-get (plist-get info :args) :command)))
      (when (and (stringp cmd)
                 (seq-some (lambda (re) (string-match-p re cmd))
                           epica-ext-destructive-patterns))
        (push (cons (current-time) cmd) epica-ext-blocked-commands)
        (cons 'block
              (format "blocked by epica-ext policy: %S matches a destructive pattern"
                      cmd))))))

(defun epica-ext--redact (info)
  "Redact secret patterns from tool results.
Returns the redacted string (a rewrite) when something was removed,
else nil (observe)."
  (let* ((result (plist-get info :result))
         (redacted (if (stringp result)
                       (seq-reduce
                        (lambda (s re) (replace-regexp-in-string re "[REDACTED]" s))
                        epica-ext-secret-patterns result)
                     result)))
    (unless (equal redacted result)
      (push (cons (current-time) result) epica-ext-redacted-results)
      redacted)))

(defun epica-ext--inject-directive ()
  "Append a standing directive to every run's system prompt.
Returns a string (epica appends it to the system prompt)."
  "You are operating a live Emacs. Prefer buffer tools over shell when possible.")

;;; --- register the extension ---

(add-hook 'epica-tool-call-hook #'epica-ext--gate-shell)
(add-hook 'epica-tool-result-hook #'epica-ext--redact)
(add-hook 'epica-before-agent-start-hook #'epica-ext--inject-directive)

(provide 'epica-ext-demo)
;;; epica-ext-demo.el ends here
