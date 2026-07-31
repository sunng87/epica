;;; spike.el --- gptel provider spike: stream tokens + round-trip one tool -*- lexical-binding: t; -*-

;; GOAL (design.org build step 1):
;;   1. Confirm gptel streaming works (tokens arrive incrementally).
;;   2. Confirm gptel tool-use round-trip works (model calls a tool, we
;;      execute it, model sees the result and continues).
;;   3. Prove buffer-native tool access (the tool reads a live Emacs buffer).
;;
;; EXIT CRITERION: the model reports a secret that lives ONLY in an Emacs
;; buffer it cannot see except via the read_buffer tool.
;;
;; Usage:  ./spike/run.sh            (defaults to anthropic)
;;         EPICA_PROVIDER=openai ./spike/run.sh

;;;###Commentary
;;
;; The "secret" is a random token placed in a dedicated buffer. The model
;; is asked to retrieve it using only the read_buffer tool. If the final
;; response contains the secret, the entire loop is proven: streaming
;; (we watched chunks arrive), tool dispatch (read_buffer ran), and
;; buffer access (the tool read a live buffer the LLM never saw as text).

;;; Code:

(require 'gptel)
(require 'subr-x)


;;; --- config from env ---

(defvar epica-spike--provider
  (or (getenv "EPICA_PROVIDER") "llamacpp")
  "One of: llamacpp, anthropic, openai, gemini.
Defaults to llamacpp (local router, no key needed).")

(defun epica-spike--env-key (var)
  "Return API key from env VAR, or error with guidance."
  (or (getenv var)
      (error "Missing %s — export it before running the spike" var)))
(defun epica-spike--llamacpp-models (host)
  "Return the router model ids at HOST as a list of symbols.
Falls back to nil (gptel defaults) if the router is unreachable."
  (let ((url (format "http://%s/v1/models" host)))
    (condition-case err
        (with-temp-buffer
          (url-insert-file-contents url)
          (goto-char (point-min))
          (let* ((data (json-read))
                 (ids (mapcar (lambda (m) (alist-get (quote id) m))
                              (alist-get (quote data) data))))
            (message "  discovered %d local models: %s"
                     (length ids) (mapconcat (quote identity) ids ", "))
            (mapcar (quote intern) (delq nil ids))))
      (error
       (message "  (could not fetch model list from %s: %S)" url err)
       nil))))


(defun epica-spike--make-backend ()
  "Construct the gptel backend per `epica-spike--provider'."
  (pcase epica-spike--provider
    ("llamacpp"
     ;; llama.cpp multi-model router is OpenAI-compatible and needs no key.
     ;; EPICA_LLMACPP_HOST overrides (default 127.0.0.1:8331); must be host:port
     ;; with NO scheme -- gptel prepends :protocol itself. We discover the
     ;; router model list so any local id (Qwen, gemma4, ...) is accepted.
     (let* ((host (or (getenv "EPICA_LLMACPP_HOST") "127.0.0.1:8331"))
            (models (epica-spike--llamacpp-models host)))
       (gptel-make-openai "llama.cpp"
         :host host
         :protocol "http"
         :endpoint "/v1/chat/completions"
         :key (lambda () "no-key-required")
         :models models
         :stream t)))
    ("anthropic"
     (gptel-make-anthropic "Claude"
       :key (lambda () (epica-spike--env-key "ANTHROPIC_API_KEY"))
       :stream t))
    ("openai"
     (gptel-make-openai "OpenAI"
       :key (lambda () (epica-spike--env-key "OPENAI_API_KEY"))
       :stream t))
    ("gemini"
     (gptel-make-gemini "Gemini"
       :key (lambda () (epica-spike--env-key "GEMINI_API_KEY"))))
    (_ (error "Unknown EPICA_PROVIDER=%s" epica-spike--provider))))

(defun epica-spike--model ()
  "Model for the active provider.
Overridable via the EPICA_MODEL env var; otherwise a sensible default
from gptel's known model list for each provider."
  (or (getenv "EPICA_MODEL")
      (pcase epica-spike--provider
        ("llamacpp"  "HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive:Q4_K_M")
        ("anthropic" "claude-sonnet-5")
        ("openai"    "gpt-4o-mini")
        ("gemini"    "gemini-1.5-flash"))))


;;; --- the buffer-native tool under test ---

(defun epica-spike--read-buffer (name)
  "Return the contents of the Emacs buffer named NAME.
This is a stand-in for epica's planned `read-buffer' tool: it reads a
LIVE buffer, not a file."
  (if-let ((buf (get-buffer name)))
      (with-current-buffer buf
        (format "[buffer %s, %d chars]\n%s"
                name (buffer-size) (buffer-string)))
    (error "No buffer named %S. Live buffers: %S"
           name (mapcar #'buffer-name (buffer-list)))))

(defun epica-spike--make-read-buffer-tool ()
  "Build the read_buffer gptel tool."
  (gptel-make-tool
   :function #'epica-spike--read-buffer
   :name "read_buffer"
   :description
   "Read the full text contents of a live Emacs buffer by its name.
Use this to inspect a buffer the user points you at. Returns the buffer
text prefixed with its size."
   :args (list '(:name "name"
                 :type string
                 :description "Exact Emacs buffer name, e.g. *epica-test*"))))


;;; --- streaming callback + completion sentinel ---

(defvar epica-spike--done nil
  "Set to t when the request reaches a terminal state.")
(defvar epica-spike--final-text nil
  "Accumulated non-streaming final text, for the secret check.")
(defvar epica-spike--turn-got-text nil
  "Non-nil if the current turn emitted streaming text chunks.")
(defvar epica-spike--turn-got-tool nil
  "Non-nil if the current turn requested a tool call.")
(defvar epica-spike--secret "spike-cabbage-9f3kq"
  "The secret planted in the test buffer.")

(defun epica-spike--callback (response info)
  "Streaming/tool callback for the spike.
RESPONSE follows gptel-request conventions; INFO is the request plist."
  ;; Always log what we got + the status, so silent failures are visible.
  (let ((status (plist-get info :status)))
    (cond
     ;; streaming text chunk
     ((stringp response)
      (message "  chunk> %S" response)
      (setq epica-spike--turn-got-text t
            epica-spike--final-text
            (concat epica-spike--final-text response)))
     ;; successful end of stream
     ((eq response t)
      (message "  [stream complete] status=%s" status))
     ;; reasoning chunk (thinking models)
     ((and (consp response) (eq (car response) 'reasoning))
      (message "  reasoning> %S" (cdr response)))
     ;; tool call (gptel is about to run the tool)
     ((and (consp response) (eq (car response) 'tool-call))
      (setq epica-spike--turn-got-tool t)
      (message "  [tool-call] %S"
               (mapcar (lambda (entry)
                         (list (gptel-tool-name (car entry)) (cadr entry)))
                       (cdr response))))
     ;; tool result (the tool ran; here is what it returned)
     ((and (consp response) (eq (car response) 'tool-result))
      (message "  [tool-result] %S"
               (mapcar (lambda (entry)
                         (let ((tool (car entry))
                               (result (caddr entry)))
                           (list (gptel-tool-name tool)
                                 (if (stringp result)
                                     (substring result 0 (min 60 (length result)))
                                   result))))
                       (cdr response))))
     ;; null response: error or abort
     ((null response)
      (message "  [NULL response] status=%s" status))
     (t
      (message "  [other] %S status=%s" response status))))
  ;; A turn ends when the stream completes (response=t) or errors. But for a
  ;; tool-calling flow, the stream ending just means ONE turn finished; gptel
  ;; will run the tool(s) and start a new request. The TRUE terminal is a turn
  ;; that produced text and requested NO tool call. Reset per-turn flags after.
  (when (eq response t)
    (if (and epica-spike--turn-got-text (not epica-spike--turn-got-tool))
        (progn (message "  [TERMINAL] final answer turn, done=t")
               (setq epica-spike--done t))
      (message "  [turn end] tool turn, continuing..."))
    (setq epica-spike--turn-got-text nil
          epica-spike--turn-got-tool nil))
  (when (and (null response) (gptel--error-p info))
    (message "  [TERMINAL] error=%s" (gptel--error-p info))
    (setq epica-spike--done t)))


;;; --- main ---

(defun epica-spike--main ()
  "Run the spike."
  (message "========================================================")
  (message "epica gptel provider spike")
  (message "  provider: %s   model: %s" epica-spike--provider (epica-spike--model))
  (message "  gptel-version: %s" gptel-version)
  (message "  curl (streaming): %s  use-tools: %s  stream: %s"
           (executable-find "curl") gptel-use-tools gptel-stream)
  (message "========================================================")

  ;; 1. plant the secret in a live buffer the LLM has never seen
  (with-current-buffer (get-buffer-create "*epica-test*")
    (erase-buffer)
    (insert (format "This buffer is only reachable via the read_buffer tool.\n"
                    ))
    (insert (format "SECRET_VALUE: %s\n" epica-spike--secret)))

  ;; 2. set up the request buffer with backend + tool
  (let* ((workbuf (get-buffer-create "*epica-spike-work*"))
         (backend (epica-spike--make-backend)))
    (with-current-buffer workbuf
      (setq-local gptel-backend backend)
      (setq-local gptel-model (intern (epica-spike--model)))
      (setq-local gptel-stream t)
      (setq-local gptel-use-tools t)
      (setq-local gptel-tools (list (epica-spike--make-read-buffer-tool)))
      (setq-local gptel-system-prompt
                  "You are a precise assistant. Use tools when asked.")
      ;; 3. fire the request
      (message "\n--- sending prompt ---")
      (let ((prompt
             (format
              (concat "There is a secret hidden in the Emacs buffer "
                      "named *epica-test*. Use the read_buffer tool to "
                      "read that buffer, then reply with ONLY the secret "
                      "value after 'SECRET_VALUE:', nothing else."))))
        (gptel-request prompt
          :stream t
          :buffer workbuf
          :callback #'epica-spike--callback))))

  ;; 4. pump the event loop until terminal (batch mode: no redisplay loop)
  ;;    Reasoning models think for a long time before acting; allow up to ~10 min.
  (let ((tick 0)
        (start (current-time)))
    (while (not epica-spike--done)
      (accept-process-output nil 0.5)
      (cl-incf tick)
      (when (= (mod tick 20) 0)        ; heartbeat every ~10s
        (message "  ...waiting (%ds, %d pumps)"
                 (time-to-seconds (time-since start)) tick))
      (when (> (time-to-seconds (time-since start)) 600) ; 10 min safety
        (message "TIMEOUT after 600s")
        (setq epica-spike--done t))))

  ;; 5. verdict
  (message "\n--- verdict ---")
  (message "final response:\n%s" (or epica-spike--final-text "(empty)"))
  (if (and epica-spike--final-text
           (string-match-p (regexp-quote epica-spike--secret)
                           epica-spike--final-text))
      (progn
        (message "\n>>> SPIKE PASSED: model recovered the buffer secret via tool <<<")
        (kill-emacs 0))
    (message "\n>>> SPIKE FAILED: secret not in response <<<")
    (kill-emacs 1)))

(epica-spike--main)

;;; spike.el ends here
