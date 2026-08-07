;;; epica.el --- an Emacs-native coding agent           -*- lexical-binding: t; -*-

;; Author: nsun
;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1") (gptel "0.9") (transient "0.4"))
;; Keywords: ai tools convenience

;; This is the epica core: a minimal agent loop on top of gptel with
;; buffer-native tools and a hook-driven extension surface.  See
;; design.org for the architecture and build order.

;;; Commentary:
;;
;; epica is built in layers.  This file (step 2 of the build order) lands
;; the foundation everything else extends:
;;
;;   - `define-epica-tool'        declarative tool definition
;;   - tool registry              `epica-tools', `epica-register-tool', ...
;;   - the agent loop             `epica-run' (async) / `epica-run-sync'
;;   - hooks                      the extension surface (see "Hooks")
;;   - a gptel bridge             epica hooks <-> gptel tool hooks
;;   - conversation rendering     to a buffer (org tree comes in step 4)
;;
;; Sessions are NOT persisted yet (that is step 4).  There is one active
;; conversation per buffer; buffer-local vars carry loop state.

;;; Code:

(require 'gptel)
(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'url)


;;; -------------------------------------------------- customization ----

(defcustom epica-backend nil
  "gptel backend epica uses for requests.
Configure via `epica-make-llamacpp-backend' or a gptel-make-* constructor.
nil means fall back to `gptel-backend'."
  :type '(choice (const :tag "Use gptel default" nil)
                 (variable :tag "gptel backend"))
  :group 'epica)

(defcustom epica-model nil
  "Model id (a symbol) epica sends.  nil falls back to `gptel-model'."
  :type '(choice (const :tag "Use gptel default" nil)
                 (symbol :tag "Model symbol"))
  :group 'epica)

(defcustom epica-system-prompt
  "You are epica, a coding agent running natively inside GNU Emacs. \
You operate on live buffers, not files. Use tools when they help. \
Be concise."
  "System prompt prepended to every epica run."
  :type 'string
  :group 'epica)

(defcustom epica-tools nil
  "List of registered epica tools (gptel-tool structs).
Populated by `define-epica-tool' / `epica-register-tool'."
  :type '(repeat (const :tag "gptel-tool"))
  :group 'epica)

(defcustom epica-conversation-buffer-name "*epica*"
  "Name of the buffer epica renders the conversation into."
  :type 'string
  :group 'epica)

(defcustom epica-conversation-major-mode #'org-mode
  "Major mode for conversation/session buffers (org headings per turn)."
  :type 'function
  :group 'epica)

(defcustom epica-visual-line t
  "If non-nil, enable `visual-line-mode' in session buffers.
Session buffers stream long lines of generated text; visual-line-mode
word-wraps them instead of forcing horizontal scrolling. Set to nil to
disable."
  :type 'boolean
  :group 'epica)

(defcustom epica-sync-timeout 600
  "Seconds `epica-run-sync' pumps the event loop before giving up."
  :type 'integer
  :group 'epica)

(defcustom epica-max-tokens 16384
  "Fallback max output tokens per request.
Used only when the user hasn't configured `gptel-max-tokens' themselves.
Reasoning models spend most of this on thinking; gptel's 4096 default
gets eaten by reasoning, truncating the answer mid-plan."
  :type 'integer
  :group 'epica)


;;; -------------------------------------------------- hooks ------------

;; The extension surface.  Every decision point in the loop fires a hook.
;; Emacs conventions: abnormal hooks where handlers receive a plist and
;; may return non-nil to influence the loop (e.g. block a tool call).

(defcustom epica-before-agent-start-hook nil
  "Abnormal hook run before an epica agent run begins.
Each function is called with no arguments; side effects run as usual.
A function may return a STRING, which is appended to the system prompt
for this run (all returned strings are collected, in hook order)."
  :type 'hook :group 'epica)

(defcustom epica-agent-settled-hook nil
  "Normal hook run when the loop settles (final answer or error)."
  :type 'hook :group 'epica)

(defcustom epica-turn-start-hook nil
  "Normal hook run at the start of each LLM turn (including after tools)."
  :type 'hook :group 'epica)

(defcustom epica-turn-end-hook nil
  "Normal hook run when an LLM turn's stream completes."
  :type 'hook :group 'epica)

(defcustom epica-tool-call-hook nil
  "Abnormal hook run before each tool call.
Each function is called with a plist:
  (:name <string> :args <plist> :tool <gptel-tool|nil>
   :buffer <string>)
To BLOCK the call, return either a string (sent to the LLM as the
error result) or (block . \"reason\"). Any other return -- including
nil -- only observes; a hook that forgets to return nil never
accidentally blocks. The first explicit block signal wins, but all
hooks still run for side effects."
  :type 'hook :group 'epica)

(defcustom epica-tool-result-hook nil
  "Abnormal hook run after each tool call.
Each function is called with a plist:
  (:name <string> :args <plist> :result <string> :buffer <string>)
All hooks run for side effects (observe). A hook may REWRITE the result
sent to the model by returning a string: the last string return wins.
Any other return (including nil) observes only -- a hook that forgets to
return nil never accidentally rewrites."
  :type 'hook :group 'epica)


;;; -------------------------------------------------- tool registry ----

;;;###autoload
(defun epica-register-tool (tool)
  "Register gptel-tool TOOL in `epica-tools' (replacing any same-named)."
  (let ((name (gptel-tool-name tool)))
    (setq epica-tools
          (cons tool (cl-remove-if
                      (lambda (tool) (equal (gptel-tool-name tool) name))
                      epica-tools)))
    tool))

(defun epica-unregister-tool (name)
  "Remove the tool whose name (string) is NAME from `epica-tools'."
  (setq epica-tools
        (cl-remove-if (lambda (tool) (equal (gptel-tool-name tool) name))
                      epica-tools)))

;;;###autoload
(defun epica-get-tool (name)
  "Return the registered gptel-tool named NAME (string), or nil."
  (cl-find-if (lambda (tool) (equal (gptel-tool-name tool) name)) epica-tools))

;;;###autoload
(defun epica-tool-names ()
  "Return the list of registered tool names (strings)."
  (mapcar #'gptel-tool-name epica-tools))


;;; -------------------------------------------------- define-epica-tool

;;;###autoload
(defmacro define-epica-tool (name args docstring &rest body)
  "Define an epica tool named NAME (a symbol).

ARGS is a list of argument specs, each of the form
  (SYMBOL TYPE DOCSTRING [keyword opts...])
where TYPE is a JSON-schema type symbol (string, integer, number,
boolean, array, object).  Optional keys per arg: `:optional',
`:enum', `:items', `:properties' (forwarded to gptel verbatim).

DOCSTRING describes the tool for the LLM.

BODY returns either a string (the result the LLM sees) or a plist
  (:content <string>   ; what the LLM sees (required)
   :details <any>      ; epica-internal, for hooks/logging (optional)
   :error <bool>)      ; mark this result as an error (optional)
Errors signaled by BODY are caught and reported to the LLM as errors.

Registers a gptel-tool in `epica-tools' and returns it.

Example:
  (define-epica-tool read-buffer
    ((name string \"Buffer name to read\"))
    \"Read a live Emacs buffer's contents.\"
    (if-let ((buf (get-buffer name)))
        (list :content (with-current-buffer buf (buffer-string)))
      (list :content (format \"No buffer named %s. Live: %S\"
                             name (mapcar #'buffer-name (buffer-list)))
            :error t)))"
  (declare (indent defun) (doc-string 3))
  (let* ((fn-name (intern (format "epica-tool--%s" name)))
         (arg-syms (mapcar #'car args))
         (gptel-args
          (mapcar
           (lambda (spec)
             (cl-destructuring-bind (sym type desc &rest rest) spec
               (append (list :name (symbol-name sym)
                             :type type
                             :description desc)
                       rest)))
           args)))
    ;; gptel applies tool args POSITIONALLY (see gptel--map-tool-args),
    ;; so the generated function takes the arg symbols in declaration order.
    (let ((args-plist-form
           (append '(list)
                   (cl-mapcan (lambda (sy)
                                 (list (intern (format ":%s" sy)) sy))
                               arg-syms))))
      `(progn
         (defun ,fn-name ,arg-syms
           ,(format "epica tool `%S'.\n%s" name docstring)
           (epica--call-with-hooks
            ,(symbol-name name)
            ,args-plist-form
            (lambda () ,@body)))
         (let ((tool (gptel-make-tool
                      :function #',fn-name
                      :name ,(symbol-name name)
                      :description ,docstring
                      :args (quote ,gptel-args))))
           (epica-register-tool tool)
           tool)))))

(defun epica--coerce-tool-result (res)
  "Coerce an epica tool BODY return value to the string gptel expects.
RES may be a string or a plist with a :content key."
  (cond
   ((stringp res) res)
   ((and (consp res) (plist-member res :content))
    (let ((content (plist-get res :content)))
      (cond ((stringp content) content)
            ((null content) "")
            (t (format "%S" content)))))
   (t (format "%S" res))))

(defun epica--call-with-hooks (name args-plist body-fn)
  "Run an epica tool BODY-FN wrapped in the call/result hooks.
NAME is the tool name string, ARGS-PLIST is the (:arg val...) the tool
was called with, BODY-FN is a zero-arg function returning the tool body
value (string or plist).
Fires `epica-tool-call-hook' first; BLOCK by returning a string reason
or (block . REASON). Any other return (nil or otherwise) only observes --
so a hook that forgets to return nil never accidentally blocks. Then runs
the body, fires `epica-tool-result-hook' with the coerced result, and
returns the coerced string gptel expects."
  (let* ((info (list :name name :args args-plist
                     :tool (epica-get-tool name)
                     :buffer (buffer-name)))
         (block-reason
          (catch 'epica--tool-blocked
            (dolist (fn epica-tool-call-hook)
              (when (functionp fn)
                (let ((r (funcall fn info)))
                  (cond
                   ((null r))                      ; observe
                   ((stringp r) (throw 'epica--tool-blocked r))
                   ((and (consp r) (eq (car r) 'block))
                    (throw 'epica--tool-blocked (cdr r)))
                   ;; any other non-nil: lenient, treat as observe
                   ))))
            nil))
         (result
          (if block-reason
              (list :content (if (stringp block-reason)
                                 block-reason
                               (format "%S" block-reason))
                    :error t)
            (condition-case err
                (funcall body-fn)
              (error (list :content (format "error: %S" err) :error t)))))
         (coerced (epica--coerce-tool-result result))
         (replacement nil))
    ;; result hooks: all run for side effects; the LAST string return wins
    ;; and replaces what the model sees.
    (dolist (fn epica-tool-result-hook)
      (when (functionp fn)
        (let ((r (funcall fn (list :name name :args args-plist
                                   :result coerced
                                   :buffer (buffer-name)))))
          (when (stringp r) (setq replacement r)))))
    (or replacement coerced)))



;;; --- tool hooks (fired from epica's own callback) -----------------
;;
;; NOTE: gptel-request (the programmatic API) does NOT run
;; `gptel-pre/post-tool-call-functions' -- those are exclusive to the
;; interactive gptel-send path. So epica fires `epica-tool-call-hook'
;; and `epica-tool-result-hook' directly from its streaming callback,
;; which DOES receive (tool-call ...) and (tool-result ...) events.
;;
;; Step 2 hooks are observe-only. Blocking a tool call before it runs
;; requires epica to own tool dispatch (handle the tool-call event, run
;; the tool itself, continue via gptel's continuation callback) -- a
;; refinement for a later build step.


;;; -------------------------------------------------- sessions ----------

(defcustom epica-session-dir
  (expand-file-name "epica/sessions/" user-emacs-directory)
  "Directory where epica session org files live (per-project subdirs)."
  :type 'directory :group 'epica)

(defcustom epica-session-buffer-prefix "*epica: "
  "Prefix for epica session buffer names."
  :type 'string :group 'epica)

(defcustom epica-session-start-hook nil
  "Normal hook run when an epica session buffer is created or opened."
  :type 'hook :group 'epica)

(defcustom epica-session-shutdown-hook nil
  "Normal hook run before an epica session buffer is killed."
  :type 'hook :group 'epica)

(defvar epica--current-session-buffer nil
  "The most recently created or opened epica session buffer.")

(defvar-local epica-session-file nil
  "Path of the org file backing the current epica session buffer.")

(defun epica--project-root ()
  "Directory used to namespace sessions for the current project.
Uses project.el when a project is known, else `default-directory'."
  (or (when-let ((pr (project-current)))
        (file-name-as-directory (directory-file-name (project-root pr))))
      (file-name-as-directory (expand-file-name default-directory))))

;;;###autoload
(defun epica-session-list ()
  "Return all session org files under `epica-session-dir'."
  (when (file-directory-p epica-session-dir)
    (directory-files-recursively epica-session-dir "\\.org$")))

(defun epica--session-save ()
  "Save the current buffer to its session file (no-op unless a session)."
  (when (and epica-session-file (buffer-file-name))
    (save-buffer)))

(defun epica--session-teardown ()
  "Save + fire `epica-session-shutdown-hook' when a session buffer dies."
  (epica--session-save)
  (run-hooks 'epica-session-shutdown-hook))

;;;###autoload
(defun epica-new-session (&optional name)
  "Create a fresh epica session buffer backed by an org file.
NAME is used for the file and buffer name; defaults to a timestamp.
The session file lives under `epica-session-dir'/project-root/.
Interactively, switches to the new session buffer."
  (interactive)
  (let* ((root (epica--project-root))
         ;; namespace under the session dir by the path relative to /
         ;; (expand-file-name ignores the base when ROOT is absolute)
         (dir (expand-file-name (file-relative-name root "/") epica-session-dir))
         (base (or name (format-time-string "%Y%m%d-%H%M%S")))
         (file (expand-file-name (concat base ".org") dir))
         (buf (generate-new-buffer (format "%s%s" epica-session-buffer-prefix base))))
    (make-directory dir t)
    (with-current-buffer buf
      (funcall epica-conversation-major-mode)
      (when epica-visual-line (visual-line-mode 1))
      (setq-local epica-session-file file)
      (setq-local buffer-file-name file)
      (setq-local buffer-save-without-query t)
      (insert (format "#+title: epica session %s\n" base))
      (add-hook 'kill-buffer-hook #'epica--session-teardown nil t)
      (run-hooks 'epica-session-start-hook))
    (setq epica--current-session-buffer buf)
    (when (called-interactively-p 'any)
      (switch-to-buffer buf))
    buf))

;;;###autoload
(defun epica-open-session (file)
  "Open session org FILE in a buffer and set up session state."
  (let ((buf (find-file-noselect file)))
    (with-current-buffer buf
      (funcall epica-conversation-major-mode)
      (when epica-visual-line (visual-line-mode 1))
      (setq-local epica-session-file file)
      (setq-local buffer-save-without-query t)
      (add-hook 'kill-buffer-hook #'epica--session-teardown nil t)
      (run-hooks 'epica-session-start-hook))
    (setq epica--current-session-buffer buf)
    buf))

;;;###autoload
(defun epica-resume ()
  "Interactively resume a saved epica session."
  (interactive)
  (let ((file (completing-read "Resume session: " (epica-session-list))))
    (switch-to-buffer (epica-open-session file))))

(defun epica--assistant-tool-section-p (text)
  "Non-nil if TEXT is a tool-only assistant section (starts with ** tool-)."
  (string-match-p "^[ \t]*\\*\\* tool-" (or text "")))

(defun epica--session-messages ()
  "Parse the current buffer (an epica session org) into ((KIND . TEXT) ...).
KIND is `user' or `assistant'. Tool-only assistant sections (no answer
text, only ** tool-* subheadings) are excluded, as are branch and
summary containers."
  (let ((msgs '()))
    (dolist (sec (epica--level1-sections))
      (pcase (car sec)
        ('user
         (push (cons 'user
                     (string-trim
                      (buffer-substring-no-properties
                       (epica--section-start sec) (epica--section-end sec))))
               msgs))
        ('assistant
         (let ((text (string-trim
                      (buffer-substring-no-properties
                       (epica--section-start sec) (epica--section-end sec)))))
           (unless (epica--assistant-tool-section-p text)
             (push (cons 'assistant text) msgs))))
        (_ nil)))
    (nreverse msgs)))

(defun epica--session-history ()
  "Alternating (user assistant ...) text list to continue the session.
Merges consecutive same-role sections defensively."
  (let (pairs)
    (dolist (m (epica--session-messages))
      (let ((kind (car m)) (text (cdr m)))
        (when (and text (not (string-empty-p text)))
          (if (and pairs (eq kind (caar pairs)))
              (setcdr (car pairs) (concat (cdr (car pairs)) "\n\n" text))
            (push (cons kind text) pairs)))))
    (mapcar #'cdr (nreverse pairs))))


;;; -------------------------------------------------- conversation -----

;; Loop state lives buffer-locally on the conversation buffer so each
;; buffer is one (potential) session.  Per-run vars are reset in epica-run.

(defvar-local epica--settled nil)
(defvar-local epica--final-text nil)
(defvar-local epica--on-settled nil)
(defvar-local epica--turn-got-text nil)
(defvar-local epica--turn-got-tool nil)
(defvar-local epica--assistant-accum nil)
(defvar-local epica--in-assistant nil)

(defun epica--conv-buffer (&optional create)
  "Return the active epica session buffer, creating a session if CREATE."
  (or (and (buffer-live-p epica--current-session-buffer)
           epica--current-session-buffer)
      (and create (epica-new-session))))

(defun epica--render-user (text)
  "Append a user turn as an org heading to the session buffer."
  (goto-char (point-max))
  (insert (format "* user\n%s\n" text)))

(defun epica--render-assistant-start ()
  "Ensure an `* assistant' org heading exists for the current turn."
  (unless epica--in-assistant
    (goto-char (point-max))
    (insert "\n* assistant\n")
    (setq epica--in-assistant t)))

(defun epica--render-assistant-chunk (chunk)
  "Stream an assistant text CHUNK under the current assistant heading."
  (epica--render-assistant-start)
  (goto-char (point-max))
  (insert chunk))

(defun epica--render-assistant-end ()
  "Finalize the current assistant turn."
  (setq epica--in-assistant nil))

(defun epica--render-reasoning (_chunk)
  "Reasoning is ephemeral thinking, not part of the conversation.
Deliberately not rendered: it would pollute the session org file."
  nil)

(defun epica--render-tool-call (entries)
  "Render tool-call ENTRIES as `** tool-call' org subheadings."
  (epica--render-assistant-start)
  (dolist (entry entries)
    (goto-char (point-max))
    (insert (format "** tool-call: %s\n#+begin_example\n%S\n#+end_example\n"
                    (gptel-tool-name (car entry)) (cadr entry)))))

(defun epica--render-tool-result (entries)
  "Render tool-result ENTRIES as `** tool-result' org subheadings."
  (dolist (entry entries)
    (goto-char (point-max))
    (let ((result (caddr entry)))
      (insert (format "** tool-result\n#+begin_example\n%s\n#+end_example\n"
                      (if (stringp result) result (format "%S" result)))))))


;;; -------------------------------------------------- agent loop -------

(defun epica--settle (&optional error-msg)
  "Mark the active loop settled, save the session, fire hooks.
If ERROR-MSG is non-nil the loop ended in error."
  (setq epica--settled t)
  (epica--session-save)
  (run-hooks 'epica-agent-settled-hook)
  (when epica--on-settled
    (funcall epica--on-settled epica--final-text error-msg)))

(defun epica--stream-callback (response info)
  "gptel streaming callback that drives the epica loop.
RESPONSE follows `gptel-request' conventions; INFO is the request plist.
Runs in the conversation buffer so buffer-local loop state is consistent."
  (let ((buf (plist-get info :buffer)))
    (when buf
      (with-current-buffer buf
        (epica--handle-stream-event response info)))))

(defcustom epica-plan-nudge
  "Please proceed with the action you described: call the tools you mentioned instead of just describing them."
  "Message sent when the model ends a turn with an unfinished plan."
  :type 'string :group 'epica)

(defvar-local epica--nudged nil
  "Non-nil if the current run already sent a plan nudge (nudge once).")

(defun epica--unfinished-plan-p (text)
  "Non-nil if TEXT reads like a plan to act, without having acted.
Catches the small-reasoning-model failure where the turn ends with
\"Let me read the buffer... then fix\" and no tool was called."
  (and (stringp text)
       (string-match-p
        "\\b\\(Let me\\|I will\\|I'll\\|I'm going to\\|First\\|Next,? I\\|I need to\\|I should\\)\\b"
        text)
       (string-match-p
        "\\b\\(read\\|fix\\|edit\\|use\\|apply\\|check\\|run\\|search\\|write\\|replace\\)\\b"
        text)))

(defun epica--nudge-continue ()
  "Nudge the model once per run to actually act; settle if already nudged.
If the model ends a second turn with an unfinished plan, accept it as
the final answer (settle) rather than stalling the loop."
  (if epica--nudged
      (epica--settle)
    (setq epica--nudged t)
    (message "epica: turn ended with an unfinished plan; nudging to continue")
    (epica--render-user epica-plan-nudge)
    (run-hooks 'epica-turn-start-hook)
    (gptel-request epica-plan-nudge
      :stream t :buffer (current-buffer)
      :system (if (epica--session-history)
                  (cons gptel-system-prompt (epica--session-history))
                gptel-system-prompt)
      :callback #'epica--stream-callback)))

(defun epica--handle-stream-event (response info)
  "Body of `epica--stream-callback', run in the conversation buffer."
  (let ((status (plist-get info :status)))
    (cond
     ;; streaming text chunk
     ((stringp response)
      (setq epica--turn-got-text t
            epica--assistant-accum (concat epica--assistant-accum response)
            epica--final-text (concat epica--final-text response))
      (epica--render-assistant-chunk response))
     ;; turn stream ended successfully
     ((eq response t)
      (epica--render-assistant-end)
      (run-hooks 'epica-turn-end-hook)
      (if (and epica--turn-got-text (not epica--turn-got-tool))
          ;; final answer turn: settle, unless it reads like an
          ;; unfinished plan (small reasoning models announce tool use
          ;; and stop). Then nudge and continue instead.
          (if (epica--unfinished-plan-p epica--final-text)
              (epica--nudge-continue)
            (epica--settle))
        ;; tool turn: gptel will run tools and start a new request
        (run-hooks 'epica-turn-start-hook))
      (setq epica--turn-got-text nil
            epica--turn-got-tool nil
            epica--assistant-accum nil))
     ;; reasoning chunk (thinking models)
     ((and (consp response) (eq (car response) 'reasoning))
      (epica--render-reasoning (cdr response)))
     ;; tool call (gptel about to run it)
     ((and (consp response) (eq (car response) 'tool-call))
      (setq epica--turn-got-tool t)
      (epica--render-tool-call (cdr response)))
     ;; tool result
     ((and (consp response) (eq (car response) 'tool-result))
      (epica--render-tool-result (cdr response)))
     ;; null response: error or abort
     ((null response)
      (when (gptel--error-p info)
        (epica--render-assistant-end)
        (epica--settle (format "error: %s" status)))))))

;;;###autoload
(cl-defun epica-run (prompt &key buffer tools system model backend on-settled)
  "Begin an epica agent run on PROMPT.  Returns immediately (async).

Renders the conversation to BUFFER (default: the active epica session).
TOOLS overrides `epica-tools'; SYSTEM/MODEL/BACKEND override the defaults.
`epica-before-agent-start-hook' runs first; string returns append to the
system prompt. When the loop settles, calls (ON-SETTLED FINAL-TEXT
ERROR-MSG) and runs `epica-agent-settled-hook'.  For a blocking variant
see `epica-run-sync'."
  ;; collect system-prompt additions from before-agent-start-hook
  (let* ((sys-extra
          (let ((acc '()))
            (dolist (fn epica-before-agent-start-hook)
              (when (functionp fn)
                (let ((r (funcall fn)))
                  (when (stringp r) (push r acc)))))
            (nreverse acc)))
         (buf (or buffer (epica--conv-buffer t)))
         (active-tools (or tools epica-tools)))
    (with-current-buffer buf
      ;; capture conversation history BEFORE rendering the new user turn,
      ;; so the new message isn't included in the template
      (let* ((history (epica--session-history))
             (summaries (epica--session-summaries))
             (base-sys (string-join
                        (cons (or system epica-system-prompt) sys-extra)
                        "\n"))
             (sys (concat
                   (if summaries
                       (concat base-sys
                               "\n\nPrevious conversation summary:\n"
                               (string-join summaries "\n\n"))
                     base-sys)
                   (epica--skills-prompt-suffix)))
             ;; gptel's :system accepts (sys user1 llm1 user2 ...) as a
             ;; conversation template; plain string when there's no history
             (gptel-system (if history (cons sys history) sys)))
        ;; reset per-run loop state
        (setq epica--nudged nil
              epica--settled nil
              epica--final-text nil
              epica--on-settled on-settled
              epica--turn-got-text nil
              epica--turn-got-tool nil
              epica--assistant-accum nil
              epica--in-assistant nil)
        ;; gptel configuration on this buffer
        (setq-local gptel-backend (or backend epica-backend gptel-backend))
        (setq-local gptel-model (or model epica-model gptel-model))
        (setq-local gptel-stream t)
        ;; respect a user-configured gptel-max-tokens; else epica's default
        (setq-local gptel-max-tokens (or gptel-max-tokens epica-max-tokens))
        (setq-local gptel-use-tools t)
        (setq-local gptel-tools active-tools)
        (setq-local gptel-system-prompt (or system epica-system-prompt))
        ;; render + fire
        (epica--render-user prompt)
        (run-hooks 'epica-turn-start-hook)
        (gptel-request prompt :stream t :buffer buf
                       :system gptel-system
                       :callback #'epica--stream-callback)))))

;;;###autoload
(cl-defun epica-run-sync (prompt &rest keys &key timeout &allow-other-keys)
  "Run `epica-run' and block until the loop settles.
Pumps the event loop (batch/test friendly).  Returns the final text.
Forwardable keys (:buffer :tools :system :model :backend) go to `epica-run'.
Bounds the wait at `epica-sync-timeout' seconds (or TIMEOUT)."
  (let (final finished (start (current-time))
        ;; strip :timeout from the forwarded keys
        (fwd (cl-loop for (k v) on keys by #'cddr
                      unless (eq k :timeout) collect k and collect v)))
    (apply #'epica-run prompt
           :on-settled (lambda (text err)
                         (setq final text finished (or err :done)))
           fwd)
    (let ((hb 0))
      (while (and (not finished)
                  (< (time-to-seconds (time-since start))
                     (or timeout epica-sync-timeout)))
        (accept-process-output nil 0.5)
        (cl-incf hb)
        (when (= (mod hb 20) 0)
          (message "epica: waiting %ds finished=%s"
                   (truncate (time-to-seconds (time-since start))) finished))))
    (unless finished
      (message "epica-run-sync: timed out after %ss" (or timeout epica-sync-timeout)))
    final))


;;; -------------------------------------------------- backends ---------

(defun epica--discover-openai-models (host protocol)
  "Return model ids at PROTOCOL://HOST/v1/models as a list of symbols.
Used by local OpenAI-compatible servers (llama.cpp router, ollama, ...).
Returns nil if unreachable."
  (let ((url (format "%s://%s/v1/models" protocol host)))
    (condition-case err
        (with-temp-buffer
          (url-insert-file-contents url)
          (goto-char (point-min))
          (let* ((data (json-read))
                 (ids (delq nil
                            (mapcar (lambda (m) (alist-get 'id m))
                                    (alist-get 'data data)))))
            (mapcar #'intern ids)))
      (error
       (message "epica: could not discover models at %s: %S" url err)
       nil))))

;;;###autoload
(defun epica-make-llamacpp-backend (&optional host)
  "Return a gptel OpenAI backend for a llama.cpp router at HOST.
HOST defaults to env EPICA_LLMACPP_HOST or 127.0.0.1:8331, as host:port
with NO scheme.  Discovers the router's model list so any local id is
accepted by gptel."
  (let* ((h (or host (getenv "EPICA_LLMACPP_HOST") "127.0.0.1:8331"))
         (models (epica--discover-openai-models h "http")))
    (gptel-make-openai "llama.cpp"
      :host h
      :protocol "http"
      :endpoint "/v1/chat/completions"
      :key (lambda () "no-key-required")
      :models models
      :stream t)))



;;; -------------------------------------------------- branching ----------

;; Org-native branching: forking archives the abandoned tail into an
;; `* epica-branch:' container (demoted one level so the session parser
;; skips it); restoring promotes it back and archives the current tail
;; (a swap). Containers may nest and survive promote/demote cycles.
;; `* epica-summary' headings hold compacted turns (see below).

(defun epica--level1-sections ()
  "Return ((TYPE (START . END)) ...) for every level-1 org heading section.
TYPE is one of `user', `assistant', `branch', `summary', `other'.
START is just after the heading line; END is the next level-1 heading
(or point-max). Sub-headings (tool-calls) are inside their section."
  (let ((sections '())
        (cur-type nil) (cur-start nil))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^\\* \\([^[:space:]]+\\)[^\n]*\n" nil t)
        (let ((word (match-string 1)))
          (when cur-type
            (push (cons cur-type (cons cur-start (match-beginning 0))) sections))
          (setq cur-type (cond
                          ((equal word "user") 'user)
                          ((equal word "assistant") 'assistant)
                          ((string-prefix-p "epica-branch" word) 'branch)
                          ((string-prefix-p "epica-summary" word) 'summary)
                          (t 'other))
                cur-start (point))))
      (when cur-type
        (push (cons cur-type (cons cur-start (point-max))) sections)))
    (nreverse sections)))

(defun epica--section-start (sec)
  "START position of level-1 section SEC (a dotted (TYPE . (START . END)))."
  (car (cdr sec)))

(defun epica--section-end (sec)
  "END position of level-1 section SEC (a dotted (TYPE . (START . END)))."
  (cdr (cdr sec)))

(defun epica--turns ()
  "Return ((START . END) ...) of each complete user->assistant turn.
A turn starts at its `* user' section and ends at its `* assistant'
section's end. Unpaired sections are ignored."
  (let ((sections (epica--level1-sections))
        (turns '()) (pending nil))
    (dolist (sec sections)
      (pcase (car sec)
        ('user (setq pending (cdr sec)))
        ('assistant (when pending
                      ;; turn = (USER-SECTION-START . ASSISTANT-SECTION-END)
                      (push (cons (car pending) (cdr (cdr sec))) turns)
                      (setq pending nil)))
        (_ (setq pending nil))))
    (nreverse turns)))

(defun epica--demote (text)
  "Demote heading lines in TEXT by one level (prepend a star)."
  (string-join
   (mapcar (lambda (line)
             (if (string-match-p "^\\*+ " line) (concat "*" line) line))
           (split-string text "\n"))
   "\n"))

(defun epica--promote (text)
  "Promote heading lines in TEXT by one level (strip one star)."
  (string-join
   (mapcar (lambda (line)
             (if (string-match-p "^\\*+ " line)
                 (substring line 1) line))
           (split-string text "\n"))
   "\n"))

(defun epica-branches ()
  "Names of `* epica-branch' containers in the current session."
  (let ((names '()))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^\\* epica-branch: \\([^ \t\n]+\\)" nil t)
        (push (match-string 1) names)))
    (nreverse names)))

(defun epica--archive-tail (start)
  "Archive the buffer region [START point-max) into a branch container."
  (let ((text (buffer-substring-no-properties start (point-max))))
    (delete-region start (point-max))
    (goto-char (point-max))
    (insert (format "\n* epica-branch: %s\n"
                    (format-time-string "%Y%m%d-%H%M%S")))
    (insert (epica--demote text))))

;;;###autoload
(defun epica-fork (&optional n)
  "Fork the session after turn N (1-based), archiving the abandoned tail.
With no N (interactive), forks after the turn containing point.
The tail becomes an `* epica-branch:' container; new turns continue the
history from the fork point. The archived branch is preserved and can be
restored with `epica-restore-branch'."
  (interactive)
  (let* ((turns (epica--turns))
         (idx (cond
               (n (1- n))
               (t (cl-position-if
                   (lambda (turn) (<= (car turn) (point) (cdr turn)))
                   turns)))))
    (unless (and idx (nth idx turns))
      (error "Fork point not found (session has %d turns)" (length turns)))
    (epica--archive-tail (cdr (nth idx turns)))
    (epica--session-save)))

;;;###autoload
(defun epica-restore-branch (name)
  "Restore branch NAME as the active path; archive the current tail.
This swaps: the named branch's turns become active, and the current
continuation is archived as a new `* epica-branch:' container."
  (interactive (list (completing-read "Restore branch: " (epica-branches))))
  (save-excursion
    (goto-char (point-min))
    (unless (re-search-forward
             (format "^\\* epica-branch: %s\n" (regexp-quote name)) nil t)
      (error "No branch named %S" name))
    (let* ((heading-start (match-beginning 0))
           (contents-start (point))
           (contents-end (save-excursion
                           (if (re-search-forward "^\\* " nil t)
                               (match-beginning 0) (point-max))))
           (contents (buffer-substring-no-properties contents-start contents-end))
           (tail (buffer-substring-no-properties contents-end (point-max))))
      (delete-region heading-start (point-max))
      (goto-char (point-max))
      (insert (epica--promote contents))
      (unless (string-empty-p (string-trim tail))
        (insert (format "\n* epica-branch: %s\n"
                        (format-time-string "%Y%m%d-%H%M%S")))
        (insert (epica--demote tail)))))
  (epica--session-save))

;;; -------------------------------------------------- compaction --------

;; Compaction: summarize the oldest complete turns into one
;; `* epica-summary' heading. On resume, summary bodies are injected
;; into the system prompt (see `epica-run'), so old context stays cheap.

(defun epica--session-summaries ()
  "Bodies of `* epica-summary' headings in order (for the system prompt)."
  (let ((summaries '()))
    (dolist (sec (epica--level1-sections))
      (pcase (car sec)
        ('summary
         (let ((start (epica--section-start sec))
               (end (epica--section-end sec)))
           (push (string-trim
                  (buffer-substring-no-properties start end))
                 summaries))))
      ;; (no-op for other types)
      )
    (nreverse summaries)))

(defun epica--strip-org-markup (text)
  "Crude strip of epica's org markup (headings, example blocks) from TEXT."
  (string-join
   (delq nil
         (mapcar
          (lambda (line)
            (unless (or (string-match-p "^\\*+ " line)
                        (string-match-p "^#\\+begin_example$" line)
                        (string-match-p "^#\\+end_example$" line))
              line))
          (split-string text "\n")))
   "\n"))

(defun epica--summarize (text)
  "Ask the model to summarize TEXT; return the summary string.
Falls back to returning TEXT unchanged if the call fails or times out."
  (condition-case err
      (let ((buf (get-buffer-create " *epica-summarize*"))
            (result nil) (done nil))
        (with-current-buffer buf
          (setq-local gptel-backend epica-backend)
          (setq-local gptel-model epica-model)
          (setq-local gptel-stream nil)
          (setq-local gptel-use-tools nil)
          (gptel-request text
            :system "You are a summarizer for an agent session. \
Summarize the conversation below concisely, preserving ALL facts, \
numbers, decisions, and the user's stated goals. 3-6 sentences."
            :buffer buf
            :callback (lambda (response _info)
                        (when (stringp response) (setq result response))
                        (setq done t))))
        (let ((start (current-time)))
          (while (and (not done)
                      (< (time-to-seconds (time-since start)) 120))
            (accept-process-output nil 0.2)))
        (or result (string-trim text)))
    (error
     (message "epica: summarization failed: %S" err)
     (string-trim text))))

;;;###autoload
(defun epica-compact (&optional keep-last)
  "Summarize the oldest turns into one `* epica-summary' heading.
Keeps the last KEEP-LAST (default 4) MESSAGES as-is. Never crosses a
branch container: compaction stops at the first container in range.
Returns the summary text."
  (interactive "P")
  (let* ((keep (or keep-last 4))
         (sections (epica--level1-sections))
         (active (cl-remove-if-not
                  (lambda (sec) (memq (car sec) '(user assistant)))
                  sections))
         (total (length active))
         (compact-count (- total (min keep total))))
    (if (<= compact-count 0)
        (progn (message "epica-compact: nothing to compact (%d messages)"
                        total)
               nil)
      (let* ((region-start (epica--section-start (car active)))
             (region-end (epica--section-end (nth (1- compact-count) active)))
             (clamped-end region-end))
        ;; stop before any container inside the region
        (dolist (sec sections)
          (when (and (eq (car sec) 'branch)
                     (> (epica--section-start sec) region-start)
                     (< (epica--section-start sec) region-end))
            (setq clamped-end (min clamped-end (epica--section-start sec)))))
        (let* ((plain (epica--strip-org-markup
                       (buffer-substring-no-properties
                        region-start clamped-end)))
               (summary (epica--summarize plain)))
          (save-excursion
            (goto-char region-start)
            (delete-region region-start clamped-end)
            (insert (format "* epica-summary: %s\n%s\n"
                            (format-time-string "%Y%m%d-%H%M%S")
                            summary)))
          (epica--session-save)
          summary)))))



;;; -------------------------------------------------- skills ------------

;; Agent Skills standard (https://agentskills.io): a skill is a
;; directory with a SKILL.md (YAML frontmatter: name, description;
;; markdown body of instructions). epica discovers skills from the same
;; directories pi and other Agent-Skills harnesses use, so skills are
;; portable across ecosystems with zero conversion.

(defcustom epica-skills-dirs
  (list (expand-file-name "epica/skills/" user-emacs-directory)
        (expand-file-name "~/.agents/skills/"))
  "Directories scanned for Agent Skills (SKILL.md files)."
  :type '(repeat directory) :group 'epica)

(defun epica--parse-frontmatter (content)
  "Parse YAML frontmatter from SKILL.md CONTENT into an alist.
Handles simple scalar values and folded (>) descriptions."
  (let* ((lines (split-string content "\n"))
         (rest lines)
         (fm '()))
    (when (and rest (string-match-p "^---[ \t]*$" (car rest)))
      (setq rest (cdr rest))
      (while (and rest (not (string-match-p "^---[ \t]*$" (car rest))))
        (push (car rest) fm)
        (setq rest (cdr rest))))
    (let ((alist '()) (fold-key nil) (fold-lines '()))
      (dolist (line (nreverse fm))
        (cond
         ((and fold-key (string-match-p "^[ \t]+" line))
          (push (string-trim line) fold-lines))
         ((string-match "^\\([a-zA-Z0-9-]+\\):[ \t]*\\(.*\\)$" line)
          (when fold-key
            (push (cons fold-key (string-join (nreverse fold-lines) " ")) alist)
            (setq fold-key nil fold-lines '()))
          (let ((key (match-string 1 line)) (val (match-string 2 line)))
            (if (or (equal val ">") (equal val ">-"))
                (setq fold-key key)
              (push (cons key val) alist))))
         (t
          (when fold-key
            (push (cons fold-key (string-join (nreverse fold-lines) " ")) alist)
            (setq fold-key nil fold-lines '())))))
      (when fold-key
        (push (cons fold-key (string-join (nreverse fold-lines) " ")) alist))
      (nreverse alist))))

;;;###autoload
(defun epica-skill-scan ()
  "Scan `epica-skills-dirs' for skills. Returns ((NAME . SKILL-MD-PATH) ...)."
  (let ((found '()))
    (dolist (dir epica-skills-dirs)
      (when (file-directory-p dir)
        (dolist (md (directory-files-recursively dir "SKILL\\.md$"))
          (let ((meta (epica--parse-frontmatter
                       (with-temp-buffer
                         (insert-file-contents md)
                         (buffer-string)))))
            (let ((name (cdr (assoc "name" meta))))
              (when name
                (push (cons name md) found)))))))
    (nreverse found)))

;;;###autoload
(defun epica-skill-load (name)
  "Return the full content of skill NAME (its SKILL.md, plus script list).
Errors list the available skills so the caller can self-correct."
  (let ((entry (assoc name (epica-skill-scan))))
    (if (not entry)
        (format "No skill named %S. Available: %S"
                name (mapcar #'car (epica-skill-scan)))
      (let* ((path (cdr entry))
             (dir (file-name-directory path))
             (content (with-temp-buffer
                        (insert-file-contents path)
                        (buffer-string)))
             (entries (directory-files dir nil "^[^.]")))
        (format "%s\n\n[skill files: %s]"
                content (string-join entries ", "))))))

(defun epica--skills-prompt-suffix ()
  "One-line-per-skill listing for the system prompt, or empty string."
  (let ((skills (epica-skill-scan)))
    (if (null skills)
        ""
      (concat
       "\n\nAvailable skills (call the load-skill tool with the name to "
       "read a skill's full instructions):\n"
       (mapconcat
        (lambda (entry)
          (let ((desc (cdr (assoc "description"
                                  (epica--parse-frontmatter
                                   (with-temp-buffer
                                     (insert-file-contents (cdr entry))
                                     (buffer-string)))))))
            (format "- %s: %s" (car entry) (or desc ""))))
        skills "\n")))))


(defcustom epica-scoped-models nil
  "List of models for `epica-cycle-model' to cycle through.
Each entry is a plist:
  (:name DeepSeek-Flash :backend BACKEND :model deepseek-v4-flash)
When nil, `epica-cycle-model' falls back to the single-backend picker."
  :type '(repeat plist)
  :group 'epica)

(defvar epica--scoped-index 0
  "Current index into `epica-scoped-models' (for `epica-cycle-model').")

;;;###autoload
(defun epica-cycle-model (&optional backward)
  "Cycle to the next scoped model (or previous with BACKWARD/prefix arg).
Sets both `epica-backend'/`epica-model' and `gptel-backend'/`gptel-model'
so the change takes effect regardless of which path `epica-run' uses.
When `epica-scoped-models' is nil, falls back to `epica-select-model'."
  (interactive "P")
  (if (null epica-scoped-models)
      (call-interactively #'epica-select-model)
    (let* ((n (length epica-scoped-models))
           (idx (mod (+ epica--scoped-index (if backward -1 1)) n))
           (entry (nth idx epica-scoped-models))
           (backend (plist-get entry :backend))
           (model (plist-get entry :model))
           (name (plist-get entry :name)))
      (setq epica--scoped-index idx)
      (setq epica-backend backend
            epica-model model
            gptel-backend backend
            gptel-model model)
      (message "epica: %s (%s / %s)"
               (or name (symbol-name model))
               (gptel-backend-name backend) model))))

(defcustom epica-deepseek-model "deepseek-v4-flash"
  "Default DeepSeek model when no EPICA_MODEL is set."
  :type 'string :group 'epica)

(defun epica--deepseek-api-key ()
  "DeepSeek API key: env DEEPSEEK_API_KEY, then auth-source.
auth-source entry: machine api.deepseek.com, user apikey,
password <key> (typically in ~/.authinfo.gpg)."
  (or (getenv "DEEPSEEK_API_KEY")
      (let ((entry (auth-source-search
                    :host "api.deepseek.com" :user "apikey" :max 1)))
        (when entry
          (let ((secret (plist-get (car entry) :secret)))
            (when (functionp secret) (funcall secret)))))))

;;;###autoload
(defun epica-make-deepseek-backend (&optional api-key)
  "Return a gptel DeepSeek backend.
API-KEY overrides; otherwise `epica--deepseek-api-key' (env then
auth-source). Requires an API key -- DeepSeek is not a local model."
  (let ((key (or api-key (epica--deepseek-api-key))))
    (unless key
      (error "No DeepSeek API key: set DEEPSEEK_API_KEY (env or .env) or add an auth-source entry"))
    (gptel-make-deepseek "DeepSeek"
      :key (lambda () key)
      :stream t)))

;;;###autoload
(defun epica-default-backend ()
  "TEST-HARNESS helper: pick DeepSeek (when a key exists) or llama.cpp.
Only the automated tests and quickstart scripts call this. In REAL
integration, do NOT use this -- configure gptel the normal way
(gptel-make-deepseek in your init, gptel's own key/auth handling) and
leave `epica-backend' nil; `epica-run' falls back to `gptel-backend'."
  (cond
   ((epica--deepseek-api-key) (epica-make-deepseek-backend))
   (t (epica-make-llamacpp-backend))))

;;;###autoload
(defun epica-default-model ()
  "TEST-HARNESS helper: default model symbol for `epica-default-backend'.
Real integration sets `epica-model' or relies on gptel's own model."
  (intern
   (or (getenv "EPICA_MODEL")
       (if (epica--deepseek-api-key)
           epica-deepseek-model
         "HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive:Q4_K_M"))))

;;;###autoload
(provide 'epica)

;; Load the submodules AFTER `provide' so that `(require 'epica)'
;; (and thus a single `use-package epica') pulls in the whole agent:
;; the buffer-native tools and the interactive UI. Placed after provide
;; to avoid a circular load (epica-tools requires epica). Loading the UI
;; is inert (define-minor-mode / transient-define-prefix define things,
;; they don't activate), so this stays safe in batch/embedded use.
(require 'epica-tools)
(require 'epica-ui)

;;; epica.el ends here
