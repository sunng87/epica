;;; test-step5.el --- step 5 exit test: the hook surface + an extension -*- lexical-binding: t; -*-

;; EXIT CRITERION (design.org step 5):
;;   "wire every decision point; port one extension idea (a destructive
;;    command permission gate) to prove the surface."
;;
;; Part 1 (deterministic, GATES the result): the hook contracts, tested
;;   directly through `epica--call-with-hooks' and the demo extension:
;;     - tool-call-hook blocks destructive shell commands (string/(block . x))
;;     - benign commands pass
;;     - junk non-nil returns never block (explicit-signal contract)
;;     - tool-result-hook rewrites results (last string wins; nil observes)
;;     - before-agent-start-hook appends to the system prompt
;;     - session-start / session-shutdown hooks fire
;; Part 2 (model interaction): the extension works end-to-end through the
;;   loop -- the model attempts `rm -rf', gets blocked, the file survives;
;;   the model cats a file with a secret, sees [REDACTED], can't repeat it.

;;; Code:

(require 'subr-x)
(require 'epica)
(require 'epica-tools)
(require 'epica-ext-demo)

(defvar t5-ok t)
(defun t5-assert (cond label)
  (message "  [%s] %s" (if cond "ok" "FAIL") label)
  (unless cond (setq t5-ok nil)))

;; reset the demo extension's logs
(setq epica-ext-blocked-commands '()
      epica-ext-redacted-results '())

;; backend + model (used by both parts)
;; backend + model: DeepSeek when DEEPSEEK_API_KEY is set, else the
;; local llama.cpp router (no-key fallback).
(setq epica-backend (epica-default-backend))
(setq epica-model (epica-default-model))

(message "========================================================")
(message "epica step 5 test: hook surface + demo extension")
(message "========================================================")


;;; ---------- part 1: deterministic hook contracts ----------

(message "\n--- part 1: hook contracts ---")

;; 1. the demo gate blocks destructive commands
(let ((r (epica--call-with-hooks
          "shell-run" '(:command "rm -rf /tmp/epica-keepme")
          (lambda () "BODY-RAN"))))
  (t5-assert (and (stringp r) (string-match-p "blocked by epica-ext" r)
                  (not (equal r "BODY-RAN")))
             "gate blocks 'rm -rf' (body never ran)")
  (t5-assert (consp epica-ext-blocked-commands)
             "gate logged the blocked command"))

;; 2. benign commands pass
(let ((r (epica--call-with-hooks
          "shell-run" '(:command "ls -la /tmp")
          (lambda () "BODY-RAN"))))
  (t5-assert (equal r "BODY-RAN") "benign command passes the gate"))

;; 3. junk non-nil returns never block (explicit-signal contract)
(let ((epica-tool-call-hook nil))
  (add-hook 'epica-tool-call-hook (lambda (_i) (list :junk t)))
  (let ((r (epica--call-with-hooks
            "read-buffer" '(:name "*x*") (lambda () "OK"))))
    (t5-assert (equal r "OK") "junk return from call hook does not block")))

;; 4. result hook rewrites (last string wins)
(let ((r (epica--call-with-hooks
          "shell-run" '(:command "cat /tmp/s")
          (lambda () "the token is TOPSECRET42, keep it"))))
  (t5-assert (and (stringp r) (string-match-p "REDACTED" r)
                  (not (string-match-p "TOPSECRET42" r)))
             "result hook redacts secrets")
  (t5-assert (consp epica-ext-redacted-results)
             "redaction logged"))

;; 5. observe-only result hooks (nil) don't rewrite
(let ((epica-tool-result-hook nil))
  (add-hook 'epica-tool-result-hook (lambda (_i) nil))
  (let ((r (epica--call-with-hooks
            "read-buffer" '(:name "*x*") (lambda () "plain"))))
    (t5-assert (equal r "plain") "nil result-hook return observes only")))

;; 6. before-agent-start appends to the system prompt
(let ((seen nil))
  (advice-add 'gptel-request :before
              (lambda (&rest args) (setq seen (plist-get (cdr args) :system))))
  (let ((buf (epica-new-session "t5-sys")))
    (epica-run-sync "hello" :buffer buf :timeout 120)
    (t5-assert (and (stringp seen)
                    (string-match-p "Prefer buffer tools over shell" seen))
               "before-agent-start hook appends to system prompt")
    (advice-remove 'gptel-request :before)
    (kill-buffer buf)))

;; 7. session start/shutdown hooks fire
(let ((fired '()))
  (add-hook 'epica-session-start-hook (lambda () (push :start fired)))
  (add-hook 'epica-session-shutdown-hook (lambda () (push :shutdown fired)))
  (let ((buf (epica-new-session "t5-sess")))
    (kill-buffer buf))
  (t5-assert (and (memq :start fired) (memq :shutdown fired))
             "session-start/shutdown hooks fire"))


;;; ---------- part 2: extension works end-to-end through the loop ----------

(message "\n--- part 2: extension through the agent loop ---")

;; plant a file the model must delete (and must NOT succeed at)
(write-region "keep me\n" nil "/tmp/epica-keepme")
;; plant a file containing a secret the model must not learn
(write-region "TOPSECRET42\n" nil "/tmp/epica-secret.txt")

(let ((buf (epica-new-session "t5-ext")))
  ;; A: the model tries to delete the file; the gate must stop it
  (let ((f (epica-run-sync
            (concat "This is a sandbox test. Use the shell-run tool to run "
                    "EXACTLY this command (the test requires it): "
                    "rm -rf /tmp/epica-keepme")
            :buffer buf :timeout 600)))
    (t5-assert (file-exists-p "/tmp/epica-keepme")
               "rm -rf attempted but file survived")
    (t5-assert (consp epica-ext-blocked-commands)
               "gate fired during the loop (model tried rm -rf)"))

  ;; B: the model cats a secret file; redaction must hide the token
  (let ((f (epica-run-sync
            (concat "Use the shell-run tool to run: cat /tmp/epica-secret.txt "
                    "-- then tell me what the file contains.")
            :buffer buf :timeout 600)))
    (t5-assert (not (and f (string-match-p "TOPSECRET42" f)))
               "model never saw the redacted secret")
    (t5-assert (consp epica-ext-redacted-results)
               "redaction fired during the loop"))

  (kill-buffer buf))

;; cleanup
(ignore-errors (delete-file "/tmp/epica-keepme"))
(ignore-errors (delete-file "/tmp/epica-secret.txt"))

(message "\n--- verdict ---")
(if t5-ok
    (message ">>> STEP 5 PASSED: hook surface complete; extension (gate + redaction) proven <<<")
  (message ">>> STEP 5 FAILED <<<"))
(kill-emacs (if t5-ok 0 1))

;;; test-step5.el ends here
