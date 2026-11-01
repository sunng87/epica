;;; epica-loop-tests.el --- offline gptel lifecycle regressions -*- lexical-binding: t; -*-

(require 'ert)
(require 'epica)

(ert-deftest epica-loop-backend-constructors-load-provider-modules-lazily ()
  (cl-letf (((symbol-function 'epica--discover-openai-models)
             (lambda (&rest _) '(local-test-model))))
    (should (epica-make-llamacpp-backend "127.0.0.1:8331"))
    (should (fboundp 'gptel-make-openai)))
  (should (epica-make-deepseek-backend "test-only-no-request"))
  (should (fboundp 'gptel-make-deepseek)))

(ert-deftest epica-loop-waits-for-automatic-tools-before-settling ()
  (with-temp-buffer
    (org-mode)
    (let ((settles 0)
          (epica-agent-settled-hook nil))
      (setq epica--running t epica--settled nil
            epica--on-settled (lambda (&rest _) (cl-incf settles)))
      (epica--render-user "Inspect the file")
      (epica--handle-stream-event "Checking the file." nil)
      ;; gptel sends this BEFORE running the automatic tool.
      (epica--handle-stream-event t '(:tool-use ((:name "read-buffer"))))
      (should (eq epica--running t))
      (should (= settles 0))
      (epica--handle-stream-event
       (cons 'tool-result (list (list (epica-get-tool "read-buffer") nil "file text"))) nil)
      (epica--handle-stream-event "Here is the answer." nil)
      (epica--handle-stream-event t nil)
      (should epica--settled)
      (should (= settles 1))
      (should (equal (epica--session-history)
                     '("Inspect the file"
                       "Checking the file.\n\nHere is the answer."))))))

(ert-deftest epica-loop-continues-confirmed-calls-or-declines-them ()
  (with-temp-buffer
    (org-mode)
    (let* ((continued nil)
           (tool (epica-get-tool "read-buffer")))
      ;; Batch mode has no user to approve a confirmation; it must
      ;; still invoke gptel's continuation rather than hang forever.
      (epica--handle-stream-event
       (cons 'tool-call
             (list (list tool '(:name "test")
                         (lambda (result) (setq continued result))))) nil)
      (should (equal continued "Tool call declined by user.")))))

(ert-deftest epica-loop-settles-empty-and-aborted-requests-once ()
  (with-temp-buffer
    (let ((settles 0) (epica-agent-settled-hook nil))
      (setq epica--running t epica--settled nil
            epica--on-settled (lambda (&rest _) (cl-incf settles)))
      (epica--handle-stream-event t nil)
      (epica--handle-stream-event 'abort nil)
      (should (and epica--settled (not epica--running)))
      (should (= settles 1)))))

(ert-deftest epica-loop-refuses-a-second-run-in-the-same-buffer ()
  (with-temp-buffer
    (org-mode)
    (let ((epica-skills-dirs nil)
          (epica-before-agent-start-hook nil)
          (requests 0))
      (cl-letf (((symbol-function 'gptel-request)
                 (lambda (&rest _) (cl-incf requests))))
        (epica-run "first" :buffer (current-buffer))
        (should-error (epica-run "second" :buffer (current-buffer))
                      :type 'user-error)
        (should (= requests 1))
        (should (equal (epica--session-history) '("first")))))))

(ert-deftest epica-loop-nudge-keeps-effective-system-and-history ()
  (with-temp-buffer
    (org-mode)
    (let ((epica-skills-dirs nil)
          (epica-before-agent-start-hook (list (lambda () "EXTENSION INSTRUCTION")))
          requests)
      (cl-letf (((symbol-function 'gptel-request)
                 (lambda (prompt &rest keys)
                   (push (list prompt (plist-get keys :system)) requests))))
        (epica-run "Inspect" :buffer (current-buffer) :system "BASE")
        (epica--handle-stream-event "Let me read the buffer." nil)
        (epica--handle-stream-event t nil))
      (let* ((nudge (car requests))
             (system (cadr nudge)))
        (should (equal (car system) "BASE\nEXTENSION INSTRUCTION"))
        (should (equal (cdr system) '("Inspect" "Let me read the buffer.")))
        (should (equal (car nudge) epica-plan-nudge))))))

(ert-deftest epica-loop-async-tool-runs-hooks-and-completes-once ()
  (eval '(define-epica-async-tool epica-test-async-tool
           ((text string "Text input")) "Return TEXT later."
           (run-at-time 0 nil
                        (lambda ()
                          (with-temp-buffer
                            (funcall callback text)
                            (funcall callback "duplicate"))))) t)
  (with-temp-buffer
    (let ((received nil)
          (epica-tool-call-hook
           (list (lambda (info)
                   (setf (plist-get info :args) '(:text "rewritten")) nil)))
          (epica-tool-result-hook
           (list (lambda (info)
                   (concat (plist-get info :result) "-filtered")))))
      (should (gptel-tool-async (epica-get-tool "epica-test-async-tool")))
      (epica-tool--epica-test-async-tool
       (lambda (result) (push result received)) "original")
      (sit-for 0.01)
      (should (equal received '("rewritten-filtered"))))))

(ert-deftest epica-loop-async-tool-blocks-before-dispatch ()
  (with-temp-buffer
    (let ((received nil) (ran nil)
          (epica-tool-call-hook (list (lambda (_info) "blocked"))))
      (epica--call-with-hooks-async
       "blocked-tool" nil (lambda (_callback _args) (setq ran t))
       (lambda (result) (setq received result)))
      (should (equal received "blocked"))
      (should-not ran))))

(ert-deftest epica-loop-call-hook-can-rewrite-tool-arguments ()
  (eval '(define-epica-tool epica-test-argument-tool
           ((text string "Text input")) "Return TEXT." text))
  (let ((epica-tool-call-hook
         (list (lambda (info)
                 (when (equal (plist-get info :name) "epica-test-argument-tool")
                   (setf (plist-get info :args) '(:text "rewritten")))
                 nil))))
    (should (equal (epica-tool--epica-test-argument-tool "original")
                   "rewritten"))))

(ert-deftest epica-loop-global-gate-runs-with-local-observers ()
  (with-temp-buffer
    (let ((epica-tool-call-hook
           (list (lambda (_info) "blocked by global policy")))
          (observed nil))
      (add-hook 'epica-tool-call-hook
                (lambda (_info) (setq observed t) nil) nil t)
      (should (equal (epica--call-with-hooks "probe" nil
                                             (lambda () "BODY RAN"))
                     "blocked by global policy"))
      (should observed))))

(ert-deftest epica-loop-selects-current-session-not-last-opened ()
  (let ((a (generate-new-buffer "epica-test-session-a"))
        (b (generate-new-buffer "epica-test-session-b")))
    (unwind-protect
        (let ((epica--current-session-buffer b))
          (with-current-buffer a
            (setq-local epica-session-file "a.org")
            (should (eq (epica--conv-buffer) a))))
      (kill-buffer a)
      (kill-buffer b))))

(ert-deftest epica-loop-ignores-stale-callbacks ()
  (with-temp-buffer
    (org-mode)
    (setq epica--running t epica--run-id 2 epica--settled nil)
    (epica--stream-callback 1 "old response" (list :buffer (current-buffer)))
    (should (equal (buffer-string) ""))
    (epica--stream-callback 2 "current response" (list :buffer (current-buffer)))
    (should (string-match-p "current response" (buffer-string)))))

(ert-deftest epica-loop-context-hooks-run-in-session-buffer ()
  (let ((target (generate-new-buffer "epica-test-context"))
        (epica-skills-dirs nil)
        (epica-before-agent-start-hook
         (list (lambda () (format "CONTEXT=%s" (buffer-name))))))
    (unwind-protect
        (with-temp-buffer
          (cl-letf (((symbol-function 'gptel-request)
                     (lambda (_prompt &rest keys)
                       (should (string-match-p
                                "CONTEXT=epica-test-context"
                                (plist-get keys :system))))))
            (epica-run "test" :buffer target)))
      (kill-buffer target))))

(provide 'epica-loop-tests)
;;; epica-loop-tests.el ends here
