;;; epica-project-tests.el --- offline VCS failure regressions -*- lexical-binding: t; -*-

(require 'ert)
(require 'epica-project)

(ert-deftest epica-project-search-reports-matches-asynchronously ()
  (let* ((root (make-temp-file "epica-search-" t))
         (default-directory (file-name-as-directory root))
         (answer nil))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" root))
          (with-temp-file (expand-file-name "source.el" root)
            (insert "FIRST NEEDLE\nSECOND NEEDLE\nTHIRD NEEDLE\n"))
          (should (project-current))
          (should (gptel-tool-async (epica-get-tool "project-search")))
          (epica-tool--project-search (lambda (text) (setq answer text))
                                      "NEEDLE" 2)
          (let ((deadline (+ (float-time) 1)))
            (while (and (null answer) (< (float-time) deadline))
              (sit-for 0.01)))
          (should (string-match-p "\\[2/3 matches\\]" (or answer "")))
          (should (string-match-p "FIRST NEEDLE" answer))
          (should-not (string-match-p "THIRD NEEDLE" answer)))
      (delete-directory root t))))

(ert-deftest epica-project-search-caps-output-in-large-repositories ()
  (let* ((root (make-temp-file "epica-search-" t))
         (default-directory (file-name-as-directory root))
         (epica-project-search-max-output 100)
         answer)
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" root))
          (with-temp-file (expand-file-name "source.el" root)
            (dotimes (i 100) (insert (format "NEEDLE %d\n" i))))
          (epica-tool--project-search
           (lambda (text) (setq answer text)) "NEEDLE" 3)
          (let ((deadline (+ (float-time) 1)))
            (while (and (null answer) (< (float-time) deadline))
              (sit-for 0.01)))
          (should (string-match-p "matches; output capped" (or answer "")))
          (should (< (length answer) 200))
          (should-not (string-match-p "NEEDLE 99" answer)))
      (delete-directory root t))))

(ert-deftest epica-project-search-times-out-without-blocking ()
  (let* ((root (make-temp-file "epica-search-" t))
         (default-directory (file-name-as-directory root))
         (epica-project-search-timeout 0.02)
         (spawn (symbol-function 'make-process))
         answer)
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" root))
          (with-temp-file (expand-file-name "source.el" root) (insert "TEXT\n"))
          (cl-letf (((symbol-function 'make-process)
                     (lambda (&rest props)
                       (apply spawn
                              (plist-put props :command
                                         (list (executable-find "sleep") "1"))))))
            (epica-tool--project-search
             (lambda (text) (setq answer text)) "TEXT" 5))
          (let ((deadline (+ (float-time) 1)))
            (while (and (null answer) (< (float-time) deadline))
              (sit-for 0.01)))
          (should (equal answer "Project search timed out")))
      (delete-directory root t))))

(ert-deftest epica-project-search-no-results-is-not-an-error ()
  (let* ((root (make-temp-file "epica-search-" t))
         (default-directory (file-name-as-directory root))
         (answer nil))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" root))
          (with-temp-file (expand-file-name "source.el" root) (insert "HELLO\n"))
          (epica-tool--project-search (lambda (text) (setq answer text))
                                      "NO-SUCH-PATTERN" 5)
          (let ((deadline (+ (float-time) 1)))
            (while (and (null answer) (< (float-time) deadline))
              (sit-for 0.01)))
          (should (equal answer "No matches.")))
      (delete-directory root t))))

(ert-deftest epica-project-vc-failed-stage-never-attempts-commit ()
  (let ((calls nil))
    (cl-letf (((symbol-function 'vc-responsible-backend) (lambda (&rest _) 'Git))
              ((symbol-function 'call-process)
               (lambda (_exe _in _dest _display &rest args)
                 (push args calls)
                 1)))
      (let ((result (epica-tool--vc-commit "test" nil)))
        (should (string-match-p "VCS commit failed" result))
        (should (equal (reverse calls) '(("add" "-A"))))))))

(ert-deftest epica-project-vc-failed-commit-is-not-reported-as-success ()
  (let ((calls nil))
    (cl-letf (((symbol-function 'vc-responsible-backend) (lambda (&rest _) 'Git))
              ((symbol-function 'call-process)
               (lambda (_exe _in _dest _display &rest args)
                 (push args calls)
                 (if (equal (car args) "commit") 1 0))))
      (let ((result (epica-tool--vc-commit "test" nil)))
        (should (string-match-p "VCS commit failed" result))
        (should (equal (mapcar #'car (reverse calls)) '("add" "commit")))))))

(provide 'epica-project-tests)
;;; epica-project-tests.el ends here
