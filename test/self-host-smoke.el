;;; self-host-smoke.el --- optional local-model smoke test -*- lexical-binding: t; -*-

;; Usage (local llama.cpp router at 127.0.0.1:8331, no API key):
;;   test/run-self-host-smoke.sh
;; This is intentionally not part of the fast/offline ERT suite.

(require 'epica)
(require 'cl-lib)

(let* ((root (make-temp-file "epica-self-host-" t))
       (default-directory (file-name-as-directory root))
       (epica-session-dir (expand-file-name "sessions/" root))
       (note (expand-file-name "self-host-note.txt" root))
       (fix-file (expand-file-name "self-host-fix.el" root))
       (token "EPICA-LOCAL-SELF-HOST-73941")
       (host (or (getenv "EPICA_LLMACPP_HOST") "127.0.0.1:8331"))
       (epica-backend (epica-make-llamacpp-backend host))
       (epica-model (car (epica--discover-openai-models host "http")))
       (tools (cl-remove-if-not
               (lambda (tool)
                 (member (gptel-tool-name tool)
                         '("open-file" "read-buffer" "save-buffer" "edit-region")))
               epica-tools))
       session answer)
  (unwind-protect
      (progn
        (unless epica-model (error "No local model at %s" host))
        (with-temp-file note (insert (format "SECRET: %s\n" token)))
        (setq session (epica-new-session "self-host-smoke"))
        (setq answer (epica-run-sync
                      "Use open-file to visit self-host-note.txt, then read-buffer to inspect it. State the SECRET token exactly in your final answer. Do not guess."
                      :buffer session :tools tools :timeout 120))
        (unless (and answer (string-match-p (regexp-quote token) answer))
          (error "Local-model self-host smoke failed: %S" answer))
        (message "SELF-HOST READ PASSED: %s" answer)
        (with-temp-file fix-file
          (insert "(defun epica-self-host-demo () (+ 1 1))\n"))
        (kill-buffer session)
        (setq session (epica-new-session "edit-smoke"))
        (epica-run-sync
         (concat "Open self-host-fix.el with open-file, read it with read-buffer, "
                 "use edit-region to replace exactly '(+ 1 1)' with '(+ 1 2)', "
                 "then use save-buffer on the file-visiting buffer. "
                 "Do not claim done before the tools run.")
         :buffer session :tools tools :timeout 120)
        (unless (equal (with-temp-buffer
                         (insert-file-contents fix-file) (buffer-string))
                       "(defun epica-self-host-demo () (+ 1 2))\n")
          (error "Local-model self-host edit did not persist"))
        (message "SELF-HOST EDIT PASSED: edit-region + save-buffer")
        (kill-buffer session)
        (setq session (epica-new-session "async-tool-smoke"))
        (setq answer (epica-run-sync
                      "Call the eshell-run tool to evaluate (+ 40 2), then report its value."
                      :buffer session :tools (list (epica-get-tool "eshell-run"))
                      :timeout 120))
        (unless (and (string-match-p "42" (or answer ""))
                     (with-current-buffer session
                       (string-match-p "\\*\\* tool-result" (buffer-string))))
          (error "Local-model async tool smoke failed: %S" answer))
        (message "SELF-HOST ASYNC TOOL PASSED: %s" answer))
    (when (buffer-live-p session) (kill-buffer session))
    (dolist (file (list note fix-file))
      (when (buffer-live-p (find-buffer-visiting file))
        (kill-buffer (find-buffer-visiting file))))
    (delete-directory root t)))

;;; self-host-smoke.el ends here
