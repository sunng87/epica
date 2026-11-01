;;; epica-buffer-tests.el --- offline live-buffer tool regressions -*- lexical-binding: t; -*-

(require 'ert)
(require 'epica)

(ert-deftest epica-read-buffer-offset-beyond-end-is-empty-not-an-error ()
  (with-temp-buffer
    (insert "one\ntwo")
    (let ((result (epica-tool--read-buffer (buffer-name) 100 10 t)))
      (should (string-match-p "2 lines" result))
      (should-not (string-match-p "error:" result)))))

(ert-deftest epica-edit-region-matches-exact-case-only ()
  (with-temp-buffer
    (insert "FOO")
    (should (string-match-p "not found"
                            (epica-tool--edit-region (buffer-name) "foo" "bar")))
    (should (equal (buffer-string) "FOO"))))

(ert-deftest epica-edit-region-rejects-overlapping-matches ()
  (with-temp-buffer
    (insert "aaa")
    (should (string-match-p "not unique"
                            (epica-tool--edit-region (buffer-name) "aa" "X")))
    (should (equal (buffer-string) "aaa"))))

(ert-deftest epica-edit-region-respects-narrowing ()
  (with-temp-buffer
    (insert "one\ntwo\n")
    (narrow-to-region (point-min) (+ (point-min) 4))
    (should (string-match-p "not found"
                            (epica-tool--edit-region (buffer-name) "two" "new")))
    (widen)
    (should (equal (buffer-string) "one\ntwo\n"))))

(ert-deftest epica-edit-region-rejects-ambiguous-buffer-name ()
  (let ((first (generate-new-buffer "epica-ambiguous-one"))
        (second (generate-new-buffer "epica-ambiguous-two")))
    (unwind-protect
        (should (string-match-p
                 "Ambiguous buffer"
                 (epica-tool--read-buffer "epica-ambiguous" nil nil nil)))
      (kill-buffer first)
      (kill-buffer second))))

(ert-deftest epica-eshell-async-waits-for-prompt-without-blocking ()
  (with-temp-buffer
    (eshell-mode)
    (let ((buf (current-buffer))
          (noninteractive nil)
          (completed nil))
      (cl-letf (((symbol-function 'epica--eshell-session-buffer)
                 (lambda () buf))
                ((symbol-function 'eshell-send-input) (lambda () nil)))
        (epica--eshell-run-async
         "echo hi" 1
         (lambda (result) (setq completed (plist-get result :content))))
        (should-not completed)
        (should epica--eshell-busy)
        (should-error (epica--eshell-run-async "echo second" 1 #'ignore)
                      :type 'user-error)
        (setq eshell-last-command-result "value"
              eshell-last-command-status 0)
        (goto-char (point-max))
        (insert "\nprinted output\n")
        (set-marker eshell-last-output-end (point))
        (run-hooks 'eshell-after-prompt-hook)
        (should (string-match-p "value" completed))
        (should (string-match-p "printed output" completed))
        (should-not epica--eshell-busy)))))

(ert-deftest epica-eshell-batch-async-tool-calls-back ()
  (let (response)
    (should (gptel-tool-async (epica-get-tool "eshell-run")))
    (epica-tool--eshell-run
     (lambda (text) (setq response text)) "(+ 1 2)" nil)
    (should (string-match-p "3" (or response "")))))

(ert-deftest epica-webfetch-retrieves-local-url-asynchronously ()
  (let ((file (make-temp-file "epica-url-"))
        (answer nil))
    (unwind-protect
        (progn
          (with-temp-file file (insert "SELF HOSTED TOOL"))
          (should (gptel-tool-async (epica-get-tool "webfetch")))
          (epica-tool--webfetch
           (lambda (text) (setq answer text)) (concat "file://" file) 100)
          (let ((deadline (+ (float-time) 1)))
            (while (and (null answer) (< (float-time) deadline))
              (sit-for 0.01)))
          (should (string-match-p "SELF HOSTED TOOL" (or answer ""))))
      (delete-file file))))

(ert-deftest epica-webfetch-times-out-and-completes-once ()
  (let ((responses nil))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (_url _callback &rest _) (generate-new-buffer " *epica-url-hung*"))))
      (epica--webfetch-async
       "http://127.0.0.1:1" nil 0.01
       (lambda (value) (push (plist-get value :content) responses)))
      (sit-for 0.03)
      (should (equal responses '("fetch timed out after 0.01s"))))))

(ert-deftest epica-open-file-reuses-unsaved-visiting-buffer-and-saves-it ()
  (let* ((root (make-temp-file "epica-file-" t))
         (file (expand-file-name "source.el" root))
         (session (generate-new-buffer "epica-file-session"))
         (visited nil))
    (unwind-protect
        (progn
          (with-temp-file file (insert "before\n"))
          (setq visited (find-file-noselect file))
          (with-current-buffer visited
            (goto-char (point-max))
            (insert "UNSAVED\n"))
          (with-current-buffer session
            (setq default-directory (file-name-as-directory root))
            (should (string-match-p "unsaved edits"
                                    (epica-tool--open-file "source.el")))
            (should (eq visited (find-buffer-visiting file)))
            (should (equal (with-current-buffer visited (buffer-string))
                           "before\nUNSAVED\n"))
            (should (string-match-p "Saved" (epica-tool--save-buffer
                                               (buffer-name visited)))))
          (should (equal (with-temp-buffer (insert-file-contents file)
                                           (buffer-string))
                         "before\nUNSAVED\n")))
      (when (buffer-live-p visited) (kill-buffer visited))
      (kill-buffer session)
      (delete-directory root t))))

(ert-deftest epica-open-file-refuses-missing-files ()
  (with-temp-buffer
    (should (string-match-p "File not found"
                            (epica-tool--open-file "missing-epica-file.el")))))

(ert-deftest epica-write-buffer-never-writes-around-a-dirty-visitor ()
  (let* ((file (make-temp-file "epica-buffer-review-"))
         (buf nil))
    (unwind-protect
        (progn
          (with-temp-file file (insert "on disk"))
          (setq buf (find-file-noselect file))
          (with-current-buffer buf (goto-char (point-max)) (insert " dirty"))
          (should (string-match-p
                   "Refusing to overwrite unsaved changes"
                   (epica-tool--write-buffer "different-buffer" "agent" file)))
          (should (equal (with-temp-buffer (insert-file-contents file)
                                           (buffer-string))
                         "on disk"))
          (should (equal (with-current-buffer buf (buffer-string))
                         "on disk dirty"))
          (should-not (get-buffer "different-buffer")))
      (when (buffer-live-p buf)
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf))
      (delete-file file))))

(ert-deftest epica-write-buffer-uses-file-visiting-buffer ()
  (let* ((file (make-temp-file "epica-buffer-review-"))
         (buf nil))
    (unwind-protect
        (progn
          (with-temp-file file (insert "old"))
          (setq buf (find-file-noselect file))
          (epica-tool--write-buffer "another-name" "new" file)
          (should (equal (with-current-buffer buf (buffer-string)) "new"))
          (should (equal (with-temp-buffer (insert-file-contents file)
                                           (buffer-string)) "new"))
          (should-not (get-buffer "another-name")))
      (when (buffer-live-p buf) (kill-buffer buf))
      (delete-file file))))

(provide 'epica-buffer-tests)
;;; epica-buffer-tests.el ends here
