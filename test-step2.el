;;; test-step2.el --- step 2 exit test: define-epica-tool + the loop -*- lexical-binding: t; -*-

;; EXIT CRITERION (design.org step 2):
;;   "model can call a tool, see its result, continue."
;;
;; This script defines one buffer-native tool via the `define-epica-tool'
;; macro, wires a couple of hooks (proving the extension surface), and
;; runs the loop via `epica-run-sync'.  Pass = the model recovers a
;; secret that lives ONLY in an Emacs buffer it can reach only via the
;; tool, AND the hooks fired.

;;; Code:

(require 'subr-x)
(require 'epica)


;;; --- backend + model (local router, no key) ---

;; backend + model: DeepSeek when DEEPSEEK_API_KEY is set, else the
;; local llama.cpp router (no-key fallback).
(setq epica-backend (epica-default-backend))
(setq epica-model (epica-default-model))


;;; --- the tool under test, via define-epica-tool ---

(define-epica-tool read-buffer
  ((name string "Exact Emacs buffer name, e.g. *epica-test*"))
  "Read the full text contents of a live Emacs buffer by name.
Returns the buffer text, or an error listing live buffers if not found."
  ;; lenient: exact match first, then substring match against live buffers.
  ;; model argument values can be slightly off (e.g. "*epica-test" missing
  ;; a trailing star); a good epica tool forgives that rather than flail.
  (let* ((all (mapcar #'buffer-name (buffer-list)))
         (buf-name (or (car (member name all))
                       (cl-find-if
                        (lambda (b) (string-match-p (regexp-quote name) b))
                        all))))
    (if-let ((buf (and buf-name (get-buffer buf-name))))
        (list :content
              (with-current-buffer buf
                (format "[buffer %s, %d chars]\n%s"
                        buf-name (buffer-size) (buffer-string))))
      (list :content
            (format "No buffer matching %S. Live buffers: %S" name all)
            :error t))))


;;; --- exercise the hook surface (the extension model) ---

;; These are exactly the kinds of things a user package would add.  Here
;; they double as test instrumentation: we assert they fired at the end.

(defvar epica-test--tool-calls nil)
(defvar epica-test--tool-results nil)
(defvar epica-test--settled nil)

(add-hook 'epica-tool-call-hook
          (lambda (info)
            (push (plist-get info :name) epica-test--tool-calls)))
(add-hook 'epica-tool-result-hook
          (lambda (info)
            (push (cons (plist-get info :name)
                        (plist-get info :result))
                  epica-test--tool-results)))
(add-hook 'epica-agent-settled-hook
          (lambda () (setq epica-test--settled t)))

;; Example of the block convention: a permission gate that lets the call
;; through, but proves the wiring.  (Uncomment the (list :block ...) form
;; to see the model get "blocked by policy" as the tool result instead.)
(add-hook 'epica-tool-call-hook
          (lambda (info)
            (when (equal (plist-get info :name) "read-buffer")
              ;; (list :block "blocked by policy (test)")
              nil)))


;;; --- run ---

(let ((secret "epica-step2-ok-7q3xz"))
  ;; plant the secret in a live buffer the LLM never sees as text
  (with-current-buffer (get-buffer-create "*epica-test*")
    (erase-buffer)
    (insert (format "Only reachable via the read_buffer tool.\nSECRET_VALUE: %s\n" secret)))

  (message "========================================================")
  (message "epica step 2 test")
  (message "  model: %s" epica-model)
  (message "  tools: %S" (epica-tool-names))
  (message "========================================================")

  (let ((final (epica-run-sync
                (concat "There is a secret in the Emacs buffer named *epica-test*. "
                        "Use the read_buffer tool to read it, then reply with ONLY "
                        "the secret value after SECRET_VALUE:, nothing else."))))
    (message "\n--- final answer ---\n%s" (or final "(empty)"))

    ;; verdict
    (message "\n--- hooks fired ---")
    (message "  tool-call-hook saw:    %S" (nreverse epica-test--tool-calls))
    (message "  tool-result-hook saw:  %S"
             (mapcar (lambda (c) (cons (car c) (and (cdr c)
                                              (substring (cdr c) 0 (min 40 (length (cdr c)))))))
                     (nreverse epica-test--tool-results)))
    (message "  agent-settled-hook:    %s" epica-test--settled)

    (message "\n--- verdict ---")
    (let ((ok (and final (string-match-p (regexp-quote secret) final))))
      (cond
       ((and ok epica-test--settled (member "read-buffer" epica-test--tool-calls))
        (message ">>> STEP 2 PASSED: model called the tool via the epica loop and recovered the secret <<<")
        (kill-emacs 0))
       (ok
        (message ">>> PARTIAL: secret recovered but hook assertions failed <<<")
        (kill-emacs 1))
       (t
        (message ">>> STEP 2 FAILED: secret not recovered <<<")
        (kill-emacs 1))))))

;;; test-step2.el ends here
