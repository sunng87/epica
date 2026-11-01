;;; epica-skill-tests.el --- project-local skill discovery -*- lexical-binding: t; -*-

(require 'ert)
(require 'epica)

(ert-deftest epica-skill-scan-discovers-project-local-skills-first ()
  (let* ((root (make-temp-file "epica-skill-project-" t))
         (global (make-temp-file "epica-skill-global-" t))
         (default-directory (file-name-as-directory root))
         (epica-skills-dirs (list global))
         (local-skill (expand-file-name ".agents/skills/self-host" root))
         (global-skill (expand-file-name "self-host" global)))
    (unwind-protect
        (progn
          (make-directory local-skill t)
          (make-directory global-skill t)
          (with-temp-file (expand-file-name "SKILL.md" local-skill)
            (insert "---\nname: self-host\ndescription: Project copy\n---\nLOCAL KNOWLEDGE\n"))
          (with-temp-file (expand-file-name "SKILL.md" global-skill)
            (insert "---\nname: self-host\ndescription: Global copy\n---\nGLOBAL KNOWLEDGE\n"))
          (should (equal (cdr (assoc "self-host" (epica-skill-scan)))
                         (expand-file-name "SKILL.md" local-skill)))
          (should (= (length (epica-skill-scan)) 1))
          (should (string-match-p "LOCAL KNOWLEDGE"
                                  (epica-skill-load "self-host")))
          (should (string-match-p "Project copy"
                                  (epica--skills-prompt-suffix))))
      (delete-directory root t)
      (delete-directory global t))))

(ert-deftest epica-skill-scan-can-be-disabled ()
  (let ((epica-skills-dirs nil))
    (should-not (epica-skill-scan))))

(provide 'epica-skill-tests)
;;; epica-skill-tests.el ends here
