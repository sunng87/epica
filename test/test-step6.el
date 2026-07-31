;;; test-step6.el --- step 6 exit test: branching + compaction -*- lexical-binding: t; -*-

;; EXIT CRITERION (design.org step 6):
;;   "clone-subtree branching; LLM-driven compaction of a heading range."
;;
;; Part A (deterministic): fork archives the tail; the parser follows the
;; branch; restore swaps back. Part B: compaction summarizes old turns
;; into an `* epica-summary' heading that feeds the system prompt, and a
;; fact planted in a compacted turn is still answerable after compaction.

;;; Code:

(require 'subr-x)
(require 'epica)
(require 'epica-tools)

(defvar t6-ok t)
(defun t6-assert (cond label)
  (message "  [%s] %s" (if cond "ok" "FAIL") label)
  (unless cond (setq t6-ok nil)))

;; backend + model: DeepSeek when DEEPSEEK_API_KEY is set, else the
;; local llama.cpp router (no-key fallback).
(setq epica-backend (epica-default-backend))
(setq epica-model (epica-default-model))

(defun t6--fresh-session (content)
  "Create a session buffer with CONTENT (org text), return it."
  (let ((buf (epica-new-session (format "t6-%d" (random 100000)))))
    (with-current-buffer buf
      (erase-buffer)
      (insert (format "#+title: epica session t6\n%s" content)))
    buf))

(defun t6--history (buf)
  "The parser's view of BUF's conversation history."
  (with-current-buffer buf (epica--session-history)))

(message "========================================================")
(message "epica step 6 test: branching + compaction")
(message "========================================================")


;;; ---------- part A: branching (deterministic) ----------

(message "\n--- part A: branching ---")

(let* ((buf (t6--fresh-session
             "* user
Tell me about A.
* assistant
A is red.
* user
Tell me about B.
* assistant
B is blue.
* user
Tell me about C.
* assistant
C is green.
"))
       (hist3 (t6--history buf)))
  (t6-assert (= (length hist3) 6) "3 turns parsed before fork")

  ;; fork after turn 1 -> tail (B, C) archived
  (with-current-buffer buf (epica-fork 1))
  (let ((hist (t6--history buf))
        (branches (with-current-buffer buf (epica-branches))))
    (t6-assert (equal hist '("Tell me about A." "A is red."))
               "after fork: history keeps turn 1 only")
    (t6-assert (= (length branches) 1) "one branch container archived")
    (t6-assert (with-current-buffer buf
                 (string-match-p "B is blue\\|C is green"
                                 (buffer-string)))
               "archived tail preserved in the org file"))

  ;; continue on the branch with a new turn
  (with-current-buffer buf
    (goto-char (point-max))
    (insert "* user
What color is A?
* assistant
A is red (confirmed).
"))
  (t6-assert (= (length (t6--history buf)) 4)
             "after continuing: history = turn 1 + new turn")

  ;; restore the archived branch -> swap: B,C active, new turn archived
  (let ((branch (with-current-buffer buf (car (epica-branches)))))
    (with-current-buffer buf (epica-restore-branch branch))
    (let ((hist (t6--history buf))
          (branches (with-current-buffer buf (epica-branches))))
      (t6-assert (equal hist
                        '("Tell me about A." "A is red."
                          "Tell me about B." "B is blue."
                          "Tell me about C." "C is green."))
                 "after restore: original 3 turns active again")
      (t6-assert (= (length branches) 1)
                 "current tail archived as a new branch")))

  (kill-buffer buf))


;;; ---------- part B: compaction ----------

(message "\n--- part B: compaction ---")

(let* ((buf (t6--fresh-session
             "* user
Remember this: the secret number is 42.
* assistant
Noted.
* user
Tell me a joke.
* assistant
Why did the chicken cross the road?
* user
What is the capital of France?
* assistant
Paris.
"))
       (hist (t6--history buf)))
  (t6-assert (= (length hist) 6) "3 turns before compaction")

  ;; compact the oldest turns, keeping the last 2 messages
  (let ((summary (with-current-buffer buf (epica-compact 2))))
    (message "  summary: %S" (and summary (substring summary 0 (min 120 (length summary)))))
    (t6-assert (stringp summary) "compaction produced a summary")
    (t6-assert (with-current-buffer buf
                 (string-match-p "\\* epica-summary" (buffer-string)))
               "summary heading exists in the session")
    (let ((hist2 (t6--history buf))
          (summaries (with-current-buffer buf (epica--session-summaries))))
      (t6-assert (= (length hist2) 2) "only the last turn remains in history")
      (t6-assert (and summaries (string-match-p "42" (car summaries)))
                 "summary preserved the secret number 42"))

    ;; model test: the fact is only in the summary now; can the model recall it?
    (let ((f (epica-run-sync
              "What is the secret number I told you earlier? Answer with only the number."
              :buffer buf :timeout 600)))
      (message "  recall answer: %S" (and f (substring f 0 (min 80 (length f)))))
      (t6-assert (and f (string-match-p "42" f))
                 "model recalls the compacted fact via the summary")))

  (kill-buffer buf))

(message "\n--- verdict ---")
(if t6-ok
    (message ">>> STEP 6 PASSED: branching (fork/restore) and compaction (summary recall) work <<<")
  (message ">>> STEP 6 FAILED <<<"))
(kill-emacs (if t6-ok 0 1))

;;; test-step6.el ends here
