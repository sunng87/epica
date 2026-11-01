;;; epica-extension-tests.el --- optional hook extension tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'epica-ext-demo)
;; Loading the demo registers global hooks; each test enables only what it needs.
(remove-hook 'epica-tool-call-hook #'epica-ext--gate-shell)
(remove-hook 'epica-tool-result-hook #'epica-ext--redact)
(remove-hook 'epica-before-agent-start-hook #'epica-ext--inject-directive)

(ert-deftest epica-extension-demo-patterns-are-customizable-lists ()
  (should (listp epica-ext-destructive-patterns))
  (should (listp epica-ext-secret-patterns))
  (should (equal (get 'epica-ext-destructive-patterns 'custom-type)
                 '(repeat regexp)))
  (should (equal (get 'epica-ext-secret-patterns 'custom-type)
                 '(repeat regexp))))

(ert-deftest epica-extension-demo-blocks-find-delete-without-running-it ()
  (let ((epica-tool-call-hook (list #'epica-ext--gate-shell))
        (ran nil))
    (should
     (string-match-p
      "blocked by epica-ext policy"
      (epica--call-with-hooks
       "eshell-run" '(:command "find . -delete")
       (lambda () (setq ran t) "ran"))))
    (should-not ran)))

(ert-deftest epica-extension-demo-redacts-tool-output ()
  (let ((epica-tool-result-hook (list #'epica-ext--redact)))
    (should (equal (epica--call-with-hooks
                    "read-buffer" '(:name "test")
                    (lambda () "header TOPSECRET123 footer"))
                   "header [REDACTED] footer"))))

;;; epica-extension-tests.el ends here
