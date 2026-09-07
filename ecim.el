;;; ecim.el --- Manage CI/CD workflows from Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ECIM contributors

;; Author: ECIM contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: tools, vc, processes
;; URL: https://github.com/nqminhuit/ecim

;;; Commentary:

;; ECIM is an Emacs-native interface to CI/CD services.  It detects
;; the repository from the current directory, authenticates per
;; repository, and shows workflow runs, jobs, logs and artifacts in
;; ordinary Emacs buffers.  GitHub Actions is the only provider so
;; far, behind a small provider interface.
;;
;; Start with `M-x ecim' inside a repository.  From the dashboard:
;;
;;   RET  jobs of the run          l  job log
;;   a    artifacts                R  run a workflow
;;   c    cancel                   G  rerun (C-u: failed jobs only)
;;   W    workflows                /  filter by branch
;;   g    refresh                  w  open in a browser
;;
;; ECIM authenticates over HTTPS, per repository.  The token normally
;; comes from the repository's own remote URL in .git/config, so a
;; personal clone and a work clone carry different credentials with no
;; further setup; an `auth-source' entry, selected by the login in
;; `ecim.account' or the `ecim-account' directory-local variable, takes
;; precedence and is the way to avoid keeping a token in plain text.
;;
;; Two requirements follow, and ECIM reports both as authentication
;; errors rather than failing obscurely later:
;;
;; * the repository must be cloned over HTTPS, unless an `auth-source'
;;   entry supplies the token -- an SSH remote carries no credential;
;; * the token must be allowed to read Actions: the `workflow' scope on
;;   a classic token, or the Actions permission on a fine-grained one.
;;   A token minted only for pushing will authenticate and then be
;;   refused by every Actions endpoint.

;;; Code:

(require 'ecim-core)
(require 'ecim-repository)
(require 'ecim-auth)
(require 'ecim-provider)
(require 'ecim-github)
(require 'ecim-ui)
(require 'ecim-runs)
(require 'ecim-logs)
(require 'ecim-artifacts)

(defconst ecim-version "0.1.0"
  "Version of ECIM.")

;;;###autoload
(defun ecim-version ()
  "Display the version of ECIM in use."
  (interactive)
  (message "ECIM %s" ecim-version))

;;;###autoload
(defun ecim-status ()
  "Describe how ECIM sees the current repository."
  (interactive)
  (let ((repo (ecim-repository-current)))
    (message "ECIM: %s at %s via %s%s"
             (ecim-repo-slug repo)
             (ecim-repo-host repo)
             (ecim-provider-for-repo repo)
             (if (ecim-repo-account repo)
                 (format " as %s" (ecim-repo-account repo))
               ""))))

(provide 'ecim)
;;; ecim.el ends here
