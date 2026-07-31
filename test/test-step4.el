;;; test-step4.el --- step 4 exit test: org session buffer + resume -*- lexical-binding: t; -*-

;; EXIT CRITERION (design.org step 4):
;;   "close and reopen a session."
;;
;; 1. Start a fresh session; the model is told a fact (secret color: teal).
;; 2. Save + kill the session buffer (CLOSE).
;; 3. Reopen the org session file (REOPEN).
;; 4. Ask a follow-up that ONLY the remembered fact can answer.
;;    Pass = the reopened session answers teal, proving the history was
;;    carried across close/reopen via the org file.

;;; Code:

(require 'subr-x)
(require 'epica)
(require 'epica-tools)

(defvar epica-test--settled nil)
(add-hook 'epica-agent-settled-hook (lambda () (setq epica-test--settled t)))

(let* ((epica-session-dir (make-temp-file "epica-sessions-" t))
       ;; backend: DeepSeek when DEEPSEEK_API_KEY is set, else local router
       (epica-backend (epica-default-backend))
       (epica-model (epica-default-model)))

  (message "========================================================")
  (message "epica step 4 test: org session + resume")
  (message "  model: %s" epica-model)
  (message "  session dir: %s" epica-session-dir)
  (message "========================================================")

  ;; --- 1. fresh session: plant a fact ---
  (let* ((buf (epica-new-session "memtest"))
         (f1 (epica-run-sync
              (concat "Remember this fact exactly: the secret color is teal. "
                      "Acknowledge with a single word.")
              :buffer buf :timeout 600)))
    (message "\n--- run 1 (plant fact) ---")
    (message "  final: %S" (and f1 (substring f1 0 (min 80 (length f1)))))
    (epica--session-save)  ; explicit save before closing
    (message "  session file: %s" (with-current-buffer buf epica-session-file))
    (kill-buffer buf)      ; CLOSE

    ;; --- 2. verify the session file is a real org file ---
    (let* ((files (epica-session-list))
           (file (car files)))
      (message "\n--- session file ---")
      (message "  files: %S" files)
      (when (and file (file-exists-p file))
        (message "  org contents:\n%s" (with-temp-buffer
                                         (insert-file-contents file)
                                         (buffer-string)))))

    ;; --- 3. reopen + continue (REOPEN) ---
    (let* ((file (car (epica-session-list)))
           (buf2 (epica-open-session file))
           (f2 (epica-run-sync
                "What color did I ask you to remember? Answer with only the color."
                :buffer buf2 :timeout 600)))
      (message "\n--- run 2 (recall) ---")
      (message "  final: %S" (and f2 (substring f2 0 (min 120 (length f2)))))
      (message "  settled: %s" epica-test--settled)

      (let* ((has-history (with-current-buffer buf2
                            (length (epica--session-history))))
             (recalled (and f2 (string-match-p "teal" (downcase f2))))
             (pass (and recalled has-history)))
        (message "\n--- assertions ---")
        (message "  history msgs in reopened session: %s" has-history)
        (message "  recalled 'teal':                  %s" recalled)
        (message "\n--- verdict ---")
        (if pass
            (message ">>> STEP 4 PASSED: session closed and reopened, history carried <<<")
          (message ">>> STEP 4 FAILED <<<"))
        (kill-emacs (if pass 0 1))))))

;;; test-step4.el ends here
