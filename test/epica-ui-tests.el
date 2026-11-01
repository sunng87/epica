;;; epica-ui-tests.el --- offline prompt routing tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'epica)

(ert-deftest epica-ui-send-without-prompt-opens-draft-buffer ()
  (let ((session (generate-new-buffer "epica-ui-session"))
        (draft nil))
    (unwind-protect
        (let ((epica--current-session-buffer session))
          (setq draft (epica-send))
          (should (with-current-buffer draft (derived-mode-p 'epica-prompt-mode))))
      (when (buffer-live-p draft) (kill-buffer draft))
      (kill-buffer session))))

(ert-deftest epica-ui-draft-sends-to-original-session ()
  (let ((source (generate-new-buffer "epica-ui-original"))
        (other (generate-new-buffer "epica-ui-other"))
        (epica--current-session-buffer nil)
        (called nil)
        (draft nil))
    (unwind-protect
        (progn
          (with-current-buffer source
            (setq-local epica-session-file "original.org")
            (setq draft (epica-compose)))
          (setq epica--current-session-buffer other)
          (with-current-buffer draft
            (insert "send to original")
            (cl-letf (((symbol-function 'epica-run)
                       (lambda (prompt &rest keys)
                         (setq called (cons prompt (plist-get keys :buffer))))))
              (epica-prompt-send)))
          (should (equal (car called) "send to original"))
          (should (eq (cdr called) source)))
      (when (buffer-live-p draft) (kill-buffer draft))
      (kill-buffer source)
      (kill-buffer other))))

(provide 'epica-ui-tests)
;;; epica-ui-tests.el ends here
