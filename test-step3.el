;;; test-step3.el --- step 3 exit test: buffer-native tools -*- lexical-binding: t; -*-

;; EXIT CRITERION (design.org step 3):
;;   "a real multi-step edit task on a live buffer."
;;
;; The agent fixes TWO bugs in a live buffer via edit-region (the
;; headline tool: live edit + free undo), then confirms via read-buffer.
;; We assert the final buffer state AND that undo entries exist.
;; Then a light check that eshell-run is stateful across calls.

;;; Code:

(require 'subr-x)
(require 'epica)
(require 'epica-tools)


;;; --- backend + model ---

;; backend + model: DeepSeek when DEEPSEEK_API_KEY is set, else the
;; local llama.cpp router (no-key fallback).
(setq epica-backend (epica-default-backend))
(setq epica-model (epica-default-model))


;;; --- plant a live buffer with two clear bugs ---

(defconst epica-test--demo-buffer "*epica-demo*")
(defconst epica-test--initial
  "# Two things to fix in this file.\n
greeting = \"hello \" + WRONG_NAME
def compute(x, y)
    return x + y
")

(with-current-buffer (get-buffer-create epica-test--demo-buffer)
  (fundamental-mode)
  (erase-buffer)
  (insert epica-test--initial))


;;; --- instrumentation ---

(defvar epica-test--calls nil)
(defvar epica-test--results nil)
(defvar epica-test--settled nil)
(add-hook 'epica-tool-call-hook
          (lambda (info) (push (plist-get info :name) epica-test--calls)))
(add-hook 'epica-tool-result-hook
          (lambda (info)
            (push (cons (plist-get info :name)
                        (let ((r (plist-get info :result)))
                          (and (stringp r) (substring r 0 (min 60 (length r))))))
                  epica-test--results)))
(add-hook 'epica-agent-settled-hook (lambda () (setq epica-test--settled t)))

(defvar epica-test--exit-code 1)


;;; --- run the multi-step edit task ---

(message "========================================================")
(message "epica step 3 test: buffer-native tools")
(message "  model: %s" epica-model)
(message "  tools: %S" (epica-tool-names))
(message "========================================================")

(let ((final
       (epica-run-sync
        (concat
         "The Emacs buffer " epica-test--demo-buffer " has exactly two bugs to fix:\n"
         "  1. The token WRONG_NAME should be replaced with: name\n"
         "  2. The line 'def compute(x, y)' is missing a trailing colon; "
         "it should be 'def compute(x, y):'\n"
         "Use the edit-region tool to fix BOTH (make old_text as small as "
         "possible while still unique in the buffer). Then use read-buffer "
         "to show the corrected buffer.\n")
        :timeout 600)))
  (message "\n--- agent final message ---\n%s" (or final "(empty)"))

  (let* ((buf (get-buffer epica-test--demo-buffer))
         (text (and buf (with-current-buffer buf (buffer-string))))
         (undo-entries (and buf (with-current-buffer buf
                                  (and (consp buffer-undo-list)
                                       (length buffer-undo-list)))))
         (fixed-name (and text (string-match-p (regexp-quote "\"hello \" + name") text)))
         (fixed-colon (and text (string-match-p (regexp-quote "def compute(x, y):") text)))
         (no-wrong (and text (not (string-match-p "WRONG_NAME" text))))
         (edit-called (member "edit-region" epica-test--calls))
         (read-called (member "read-buffer" epica-test--calls)))

    (message "\n--- buffer state ---\n%s" (or text "(buffer gone)"))
    (message "\n--- assertions ---")
    (message "  greeting fixed:    %s" fixed-name)
    (message "  colon fixed:       %s" fixed-colon)
    (message "  WRONG_NAME gone:   %s" no-wrong)
    (message "  undo entries:      %s" undo-entries)
    (message "  edit-region used:  %s" edit-called)
    (message "  read-buffer used:  %s" read-called)
    (message "  agent settled:     %s" epica-test--settled)

    (let ((pass (and fixed-name fixed-colon no-wrong
                     (integerp undo-entries) (> undo-entries 0)
                     edit-called epica-test--settled)))
      (message "\n--- verdict ---")
      (if pass
          (message ">>> STEP 3 PASSED: multi-step live-buffer edit succeeded, undo available <<<")
        (message ">>> STEP 3 FAILED <<<"))
      (setq epica-test--exit-code (if pass 0 1))))

  ;; --- light shell statefulness check (reported, not gate) ---
  (message "\n--- shell statefulness check ---")
  (condition-case err
      (let* ((r1 (epica--shell-send-and-capture "cd /tmp" 15))
             (r2 (epica--shell-send-and-capture "pwd" 15))
             (stateful (string-match-p "/tmp" (car r2))))
        (message "  cd /tmp -> exit %d" (cdr r1))
        (message "  pwd     -> %S (exit %d)" (car r2) (cdr r2))
        (message "  stateful cwd preserved: %s" (if stateful "YES" "NO"))
        (unless stateful
          (message "  (shell statefulness not confirmed in this run; tool is delivered)")))
    (error
     (message "  shell check errored: %S (tool is delivered; headless shell)" err)))

  (kill-emacs epica-test--exit-code))

;;; test-step3.el ends here
