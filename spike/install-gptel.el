;;; install-gptel.el --- Install gptel into a project-local elpa -*- lexical-binding: t; -*-

;; Isolated install: nothing touches the user's ~/.emacs.d or ~/.minimal-emacs.d.
;; Run: emacs --batch -l spike/install-gptel.el

(require 'package)

;; Project-local package dir (absolute, resolved relative to this file)
(setq package-user-dir
      (expand-file-name ".elpa" (file-name-directory
                                 (file-truename load-file-name))))

;; MELPA + GNU
(setq package-archives
      '(("gnu"   . "https://elpa.gnu.org/packages/")
        ("melpa" . "https://melpa.org/packages/")))

(package-initialize)
(unless package-archive-contents
  (package-refresh-contents))

;; Install gptel (and its deps) into the project-local dir
(unless (package-installed-p 'gptel)
  (package-install 'gptel))


(message "=== installed into: %s ===" package-user-dir)
(message "=== gptel version: %s ===" (when (featurep 'gptel) gptel-version))
(message "=== gptel files present ===")
(dolist (f (directory-files package-user-dir t "\\`gptel"))
  (message "  %s" f))

;;; install-gptel.el ends here
