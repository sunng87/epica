;;; epica-ui.el --- interactive commands + transient menu for epica -*- lexical-binding: t; -*-

;; The interactive layer (build step 8): M-x commands, a transient
;; menu, and a minor mode for session buffers. Core (epica.el) stays
;; UI-free; this file is what a user loads to drive epica interactively.

;;; Code:

(require 'epica)
(require 'epica-tools)
(require 'transient)

;;; -------------------------------------------------- commands ----------

(defun epica ()
  "Start (or resume) the active epica session and show it.
The agent runs in the session buffer; type C-c C-s (in
`epica-minor-mode') or M-x epica-send to prompt it."
  (interactive)
  (let ((buf (epica--conv-buffer t)))
    (switch-to-buffer buf)
    (message "epica: C-c C-s to send a prompt, C-c C-m for the menu")))

(defun epica-send (prompt)
  "Send PROMPT to the agent in the active session buffer (async).
The answer streams into the session buffer as it is generated.
Interactively (PROMPT nil), opens the prompt buffer to draft a
multi-line prompt instead of reading the minibuffer."
  (interactive)
  (if (null prompt)
      (epica-compose)
    (let ((buf (epica--conv-buffer t)))
      (pop-to-buffer buf)
      (epica-run prompt :buffer buf)
      (message "epica: agent started in %s" (buffer-name buf)))))

(defun epica-select-model (&optional model)
  "Choose the model for epica runs.
Interactively, completing-read over the backend's model list.
With MODEL (a string), set it directly."
  (interactive)
  (let* ((backend (or epica-backend gptel-backend))
         (models (and backend (mapcar #'symbol-name (gptel-backend-models backend))))
         (choice (or model
                     (completing-read
                      "Model: " models nil t
                      (and epica-model (symbol-name epica-model))))))
    (setq epica-model (intern choice))
    (message "epica model: %s" choice)))

(defun epica-view-skill (name)
  "Display skill NAME's SKILL.md (and file list) in a help buffer."
  (interactive (list (completing-read
                      "Skill: " (mapcar #'car (epica-skill-scan)) nil t)))
  (let ((entry (assoc name (epica-skill-scan))))
    (if (not entry)
        (message "No skill named %S" name)
      (with-output-to-temp-buffer "*epica-skill*"
        (princ (epica-skill-load name))))))

(defun epica-compact-session ()
  "Compact the current session's oldest turns (interactive wrapper)."
  (interactive)
  (epica-compact 4))

;;; -------------------------------------------------- prompt buffer ------

;; Draft prompts in a dedicated buffer, magit-commit style: write a
;; multi-line prompt, C-c C-c to send, C-c C-k to cancel.

(defcustom epica-prompt-buffer-name "*epica-prompt*"
  "Name of the buffer used to draft prompts."
  :type 'string :group 'epica)

(defvar-local epica-prompt--session-buffer nil
  "Session buffer the draft prompt will be sent to.")

(define-derived-mode epica-prompt-mode text-mode "epica-prompt"
  "Major mode for drafting epica prompts.

Write a multi-line prompt, then send it with \[epica-prompt-send]
(C-c C-c) or cancel with \[epica-prompt-cancel] (C-c C-k)."
  (setq-local header-line-format
              "epica prompt: C-c C-c send · C-c C-k cancel"))

(define-key epica-prompt-mode-map (kbd "C-c C-c") #'epica-prompt-send)
(define-key epica-prompt-mode-map (kbd "C-c C-k") #'epica-prompt-cancel)

(defun epica-compose ()
  "Open a buffer to draft a prompt for the agent (C-c C-c sends).
The prompt is sent to the active epica session; the session buffer is
shown afterwards so the answer streams in view."
  (interactive)
  (let* ((session (epica--conv-buffer t))
         (buf (get-buffer-create epica-prompt-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'epica-prompt-mode)
        (epica-prompt-mode))
      (setq-local epica-prompt--session-buffer session)
      (erase-buffer))
    (when (called-interactively-p 'any)
      ;; dedicated window: sending/cancelling can then close it cleanly
      (pop-to-buffer buf '(display-buffer-pop-up-window (dedicated . t))))
    buf))

(defun epica-prompt-send ()
  "Send the draft prompt to the agent and close the prompt window."
  (interactive)
  (let ((prompt (string-trim (buffer-string)))
        (win (get-buffer-window)))
    (when (string-empty-p prompt)
      (user-error "Empty prompt — nothing to send"))
    (kill-buffer)
    (when (window-live-p win)
      (quit-window nil win))
    (epica-send prompt)))

(defun epica-prompt-cancel ()
  "Cancel the draft prompt without sending; close the prompt window."
  (interactive)
  (let ((win (get-buffer-window)))
    (kill-buffer)
    (when (window-live-p win)
      (quit-window nil win))))

;;; -------------------------------------------------- minor mode --------

(define-minor-mode epica-minor-mode
  "Minor mode with epica keybindings for session buffers.

\\<epica-minor-mode-map>
\\[epica-send]             send a prompt to the agent
\\[epica-compose]          open the prompt-drafting buffer
\\[epica-menu]             open the epica menu
\\[epica-new-session]      start a new session
\\[epica-resume]           resume a saved session
\\[epica-compact-session]  compact the session"
  :lighter " epica"
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c C-s") #'epica-send)
            (define-key map (kbd "C-c C-p") #'epica-compose)
            (define-key map (kbd "C-c C-m") #'epica-menu)
            (define-key map (kbd "C-c C-n") #'epica-new-session)
            (define-key map (kbd "C-c C-r") #'epica-resume)
            (define-key map (kbd "C-c C-c") #'epica-compact-session)
            map))

;;; -------------------------------------------------- transient menu ----

(transient-define-prefix epica-menu ()
  "epica: interactive agent menu."
  [["Session"
    ("n" "New session" epica-new-session)
    ("r" "Resume session" epica-resume)
    ("b" "Restore branch" epica-restore-branch)
    ("c" "Compact session" epica-compact-session)]
   ["Model & skills"
    ("m" "Select model" epica-select-model)
    ("s" "View skill" epica-view-skill)]]
  [["Actions"
    ("p" "Compose prompt" epica-compose)]])

(provide 'epica-ui)
;;; epica-ui.el ends here
