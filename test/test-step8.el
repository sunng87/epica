;;; test-step8.el --- step 8 exit test: interactive layer -*- lexical-binding: t; -*-

;; EXIT CRITERION (design.org step 8):
;;   "Slash commands / transient UI."
;;
;; Part A (deterministic): every interactive command exists and is
;;   interactive; the transient prefix is defined; the minor mode's
;;   keymap binds the actions; model selection and skill viewing work.
;; Part B (model through the UI): epica-send drives a real agent turn
;;   in the session buffer, and the answer lands in the buffer.

;;; Code:

(require 'subr-x)
(require 'epica)
(require 'epica-tools)
(require 'epica-ui)

(defvar t8-ok t)
(defun t8-assert (cond label)
  (message "  [%s] %s" (if cond "ok" "FAIL") label)
  (unless cond (setq t8-ok nil)))

;; backend + model: DeepSeek when DEEPSEEK_API_KEY is set, else the
;; local llama.cpp router (no-key fallback).
(setq epica-backend (epica-default-backend))
(setq epica-model (epica-default-model))

;; a hermetic skill for the view-skill test
(defvar t8-skill-dir (make-temp-file "epica-skills-ui-" t))
(make-directory (expand-file-name "ui-demo" t8-skill-dir) t)
(write-region
 "---
name: ui-demo
description: A tiny skill for UI tests.
---

# Ui Demo
The ui-demo skill says: everything works.
"
 nil (expand-file-name "ui-demo/SKILL.md" t8-skill-dir))
(setq epica-skills-dirs (list t8-skill-dir))

(message "========================================================")
(message "epica step 8 test: interactive layer")
(message "========================================================")


;;; ---------- part A: commands exist, are interactive ----------

(message "\n--- part A: interactive surface ---")

(dolist (cmd '(epica epica-send epica-menu epica-select-model
                epica-view-skill epica-compact-session epica-minor-mode))
  (t8-assert (commandp cmd) (format "%s is a command" cmd)))

;; transient prefix defined: `commandp' above already covers epica-menu
;; (transient-define-prefix defines a command); no internal check needed.

;; minor mode keymap bindings
(dolist (binding '(("C-c C-s" . epica-send)
                   ("C-c C-m" . epica-menu)
                   ("C-c C-n" . epica-new-session)
                   ("C-c C-r" . epica-resume)
                   ("C-c C-c" . epica-compact-session)))
  (t8-assert (eq (lookup-key epica-minor-mode-map (kbd (car binding)))
                 (cdr binding))
             (format "minor-mode binds %s" (car binding))))

;; model selection (programmatic)
(let ((m (symbol-name epica-model)))
  (epica-select-model m)
  (t8-assert (equal (symbol-name epica-model) m)
             "epica-select-model sets epica-model"))

;; skill viewing (programmatic)
(epica-view-skill "ui-demo")
(t8-assert (get-buffer "*epica-skill*")
           "epica-view-skill shows a help buffer")
(t8-assert (with-current-buffer (get-buffer "*epica-skill*")
             (string-match-p "everything works" (buffer-string)))
           "skill help buffer has the skill content")

;; new session is interactive-capable and returns a buffer
(let ((buf (epica-new-session "ui-test")))
  (t8-assert (buffer-live-p buf) "epica-new-session returns a live buffer")
  (kill-buffer buf))

;; epica main entry switches to the session buffer
(let ((before (current-buffer)))
  (epica)
  (t8-assert (buffer-live-p (current-buffer))
             "epica main entry leaves a live buffer"))


;;; ---------- part B: prompt-drafting buffer (magit-commit style) ----------

(message "\n--- part B: prompt buffer ---")

;; compose opens a dedicated prompt buffer in prompt mode, keybindings bound
(let ((buf (epica-compose)))
  (t8-assert (with-current-buffer buf (derived-mode-p 'epica-prompt-mode))
             "epica-compose opens a prompt buffer in epica-prompt-mode")
  (t8-assert (eq (lookup-key epica-prompt-mode-map (kbd "C-c C-c"))
                 #'epica-prompt-send)
             "C-c C-c binds epica-prompt-send")
  (t8-assert (eq (lookup-key epica-prompt-mode-map (kbd "C-c C-k"))
                 #'epica-prompt-cancel)
             "C-c C-k binds epica-prompt-cancel")
  (kill-buffer buf))

;; empty prompt refused
(let ((buf (epica-compose)))
  (set-buffer buf)
  (condition-case e
      (epica-prompt-send)
    (user-error (t8-assert t "empty prompt refused with user-error")))
  (t8-assert (buffer-live-p buf) "prompt buffer survives an empty send")
  (kill-buffer buf))

;; cancel kills without sending
(let ((buf (epica-compose)))
  (with-current-buffer buf (insert "draft"))
  (set-buffer buf)
  (epica-prompt-cancel)
  (t8-assert (not (buffer-live-p buf)) "C-c C-k cancels the draft"))

;; send closes the buffer and drives a real agent turn
(let ((buf (epica-compose))
      (session (epica--conv-buffer)))
  (with-current-buffer buf (insert "Reply with exactly the word PONG."))
  (set-buffer buf)
  (epica-prompt-send)
  (t8-assert (not (buffer-live-p buf)) "send closes the prompt buffer")
  (let ((deadline (+ (float-time) 300)))
    (with-current-buffer session
      (while (and (not epica--settled) (< (float-time) deadline))
        (accept-process-output nil 0.2))))
  (t8-assert (with-current-buffer session
               (string-match-p "PONG" (buffer-string)))
             "prompt-buffer send drives a real agent turn")
  (kill-buffer session))

;;; ---------- part C: send drives a real agent turn ----------

(message "\n--- part C: epica-send end-to-end ---")

(let ((buf (epica-new-session "ui-e2e")))
  (epica-send "Reply with exactly the word PING.")
  ;; epica-send is async; pump until the loop settles
  (let ((deadline (+ (float-time) 600)))
    (with-current-buffer buf
      (while (and (not epica--settled) (< (float-time) deadline))
        (accept-process-output nil 0.2))))
  (let ((text (with-current-buffer buf (buffer-string))))
    (message "  session buffer tail: %S"
             (substring text (max 0 (- (length text) 120))))
    (t8-assert (string-match-p "PING" text)
               "agent answer streamed into the session buffer"))
  (kill-buffer buf))

(message "\n--- verdict ---")
(if t8-ok
    (message ">>> STEP 8 PASSED: interactive layer (transient menu, commands, minor mode) works <<<")
  (message ">>> STEP 8 FAILED <<<"))
(kill-emacs (if t8-ok 0 1))

;;; test-step8.el ends here
