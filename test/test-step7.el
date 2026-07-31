;;; test-step7.el --- step 7 exit test: skills loader -*- lexical-binding: t; -*-

;; EXIT CRITERION (design.org step 7):
;;   "Agent Skills standard; port one pi skill verbatim."
;;
;; Part A (deterministic): epica discovers the REAL pi skills in
;; ~/.agents/skills/ (zero-conversion portability), parses their
;; frontmatter, and the load-skill tool returns their content.
;; Part B (model): the system prompt lists available skills; the model
;; discovers a planted skill, loads it via the tool, and answers from it.

;;; Code:

(require 'subr-x)
(require 'epica)
(require 'epica-tools)

(defvar t7-ok t)
(defun t7-assert (cond label)
  (message "  [%s] %s" (if cond "ok" "FAIL") label)
  (unless cond (setq t7-ok nil)))

;; --- make a hermetic test skill dir (so the test doesn't depend on
;;     the real ~/.agents/skills being present) ---
(defvar t7-skill-dir (make-temp-file "epica-skills-test-" t))
(make-directory (expand-file-name "weather-lore" t7-skill-dir) t)
(write-region
 "---
name: weather-lore
description: >
  Facts about weather in epicaland, the fictional country where
  everything is unusual. Use when asked about epicaland weather.
---

# Weather Lore

Epicaland weather facts:

- The sky in epicaland is always GREEN during the day.
- It rains chocolate on Tuesdays.
"
 nil (expand-file-name "weather-lore/SKILL.md" t7-skill-dir))

;; --- point epica at BOTH the hermetic dir and the real pi dir ---
(setq epica-skills-dirs
      (list t7-skill-dir
            (expand-file-name "~/.agents/skills/")))

;; backend + model: DeepSeek when DEEPSEEK_API_KEY is set, else the
;; local llama.cpp router (no-key fallback).
(setq epica-backend (epica-default-backend))
(setq epica-model (epica-default-model))

(message "========================================================")
(message "epica step 7 test: skills loader")
(message "========================================================")


;;; ---------- part A: discovery + parsing (deterministic) ----------

(message "\n--- part A: skill discovery ---")

(let ((skills (epica-skill-scan)))
  (t7-assert (assoc "weather-lore" skills) "hermetic skill discovered")
  ;; the real pi skills are readable verbatim (portability proof)
  (t7-assert (assoc "code-review" skills) "pi skill 'code-review' discovered from ~/.agents/skills")
  (t7-assert (assoc "skill-creator" skills) "pi skill 'skill-creator' discovered")
  (t7-assert (>= (length skills) 7) "at least 7 skills total (1 hermetic + 6 pi)"))

;; frontmatter parsing: name + folded multiline description
(let* ((c (with-temp-buffer
            (insert-file-contents
             (expand-file-name "weather-lore/SKILL.md" t7-skill-dir))
            (buffer-string)))
       (fm (epica--parse-frontmatter c)))
  (t7-assert (equal (cdr (assoc "name" fm)) "weather-lore")
             "frontmatter name parsed")
  (t7-assert (string-match-p "epicaland" (cdr (assoc "description" fm)))
             "folded multiline description parsed"))

;; the load-skill tool returns content
(let ((content (epica-skill-load "weather-lore")))
  (t7-assert (string-match-p "sky in epicaland is always GREEN" content)
             "load-skill returns the skill body")
  (t7-assert (string-match-p "skill files" content)
             "load-skill lists skill files"))

;; system-prompt suffix mentions skills
(let ((suffix (epica--skills-prompt-suffix)))
  (t7-assert (and (string-match-p "weather-lore" suffix)
                  (string-match-p "code-review" suffix))
             "system prompt lists available skills"))

;; unknown skill errors helpfully
(let ((content (epica-skill-load "no-such-skill")))
  (t7-assert (string-match-p "No skill named" content)
             "unknown skill errors with available list"))


;;; ---------- part B: the model discovers + loads a skill ----------

(message "\n--- part B: model loads a skill via the tool ---")

(let ((buf (epica-new-session "t7-skills")))
  (let ((f (epica-run-sync
            (concat "There is a skill named 'weather-lore' that you may need. "
                    "First answer this: what color is the sky in epicaland? "
                    "If you don't know, use the load-skill tool to read the "
                    "weather-lore skill, then answer with only the color.")
            :buffer buf :timeout 600)))
    (message "  answer: %S" (and f (substring f 0 (min 120 (length f)))))
    (t7-assert (and f (string-match-p "green" (downcase f)))
               "model loaded the skill and answered from it"))
  (kill-buffer buf))

(message "\n--- verdict ---")
(if t7-ok
    (message ">>> STEP 7 PASSED: skills loader reads pi skills verbatim; model loads skills on demand <<<")
  (message ">>> STEP 7 FAILED <<<"))
(kill-emacs (if t7-ok 0 1))

;;; test-step7.el ends here
