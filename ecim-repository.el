;;; ecim-repository.el --- Repository detection for ECIM  -*- lexical-binding: t; -*-

;;; Commentary:

;; Works out which repository the current buffer belongs to by asking
;; Git.  Remote URLs are parsed for host/owner/name only, and any
;; credential in them is dropped here: repository identity is not a
;; secret and is cached, passed around and printed.  Reading the token
;; out of the remote is a separate step, done on demand and kept out of
;; these structures (see `ecim-auth--from-remote-url').

;;; Code:

(require 'ecim-core)

(defcustom ecim-remote-name "origin"
  "Name of the Git remote ECIM inspects to identify the repository."
  :type 'string
  :group 'ecim)

(defcustom ecim-git-executable "git"
  "Git program used for repository detection."
  :type 'string
  :group 'ecim)

(defvar ecim-account nil
  "Login name ECIM should authenticate as in this repository.
Usually set through a directory-local variable or the Git
configuration key `ecim.account'.")
;;;###autoload
(put 'ecim-account 'safe-local-variable #'stringp)

(defvar ecim-repository--cache (make-hash-table :test #'equal)
  "Cache of detected repositories, keyed by worktree root.")

(defun ecim--git-output (directory &rest args)
  "Run Git with ARGS in DIRECTORY and return trimmed output, or nil."
  (let ((default-directory (or directory default-directory)))
    (with-temp-buffer
      (let ((process-environment (cons "GIT_TERMINAL_PROMPT=0" process-environment)))
        (when (eq 0 (apply #'process-file ecim-git-executable nil t nil args))
          (let ((out (string-trim (buffer-string))))
            (unless (string-empty-p out) out)))))))

(defun ecim-repository--parse-remote (url)
  "Parse remote URL into a plist of :host, :owner and :name.
Handles HTTPS, scp-style and ssh:// forms, with or without a
trailing \".git\".  Any userinfo (a username, or a username and
token) is stripped, so the result can be cached and displayed
freely.  Returns nil if URL cannot be parsed."
  (when (stringp url)
    (let ((rest (string-trim url))
          (schemed nil))
      ;; Drop the scheme, then any "user@" or "user:token@" prefix.
      (when (string-match "\\`[a-zA-Z][a-zA-Z0-9+.-]*://" rest)
        (setq schemed t
              rest (substring rest (match-end 0))))
      (when (string-match "\\`[^/]*@" rest)
        (setq rest (substring rest (match-end 0))))
      ;; Only a URL with a scheme can carry a port.  In the scp form the
      ;; colon separates the path, so "git@host:123/repo.git" owns the
      ;; organisation "123" and has no port at all.
      (when (string-match (if schemed
                              "\\`\\([^/:]+\\)\\(?::[0-9]+\\)?/+\\(.+\\)\\'"
                            "\\`\\([^/:]+\\)[:/]+\\(.+\\)\\'")
                          rest)
        (let ((host (downcase (match-string 1 rest)))
              (path (match-string 2 rest)))
          (setq path (replace-regexp-in-string "/+\\'" "" path))
          (setq path (replace-regexp-in-string "\\.git\\'" "" path))
          (when (string-match "\\`\\(.+\\)/\\([^/]+\\)\\'" path)
            (list :host host
                  :owner (match-string 1 path)
                  :name (match-string 2 path))))))))

(defun ecim-repository-root (&optional directory)
  "Return the Git worktree root containing DIRECTORY, or nil."
  (let ((root (ecim--git-output (or directory default-directory)
                                "rev-parse" "--show-toplevel")))
    (when root (file-name-as-directory root))))

(defun ecim-repository--account (root)
  "Return the login configured for the repository at ROOT, if any."
  (or (and (stringp ecim-account) ecim-account)
      (ecim--git-output root "config" "--get" "ecim.account")))

(defun ecim-repository-current (&optional directory)
  "Return an `ecim-repo' for DIRECTORY, signalling if there is none.
Results are cached per worktree; call `ecim-repository-invalidate'
after changing remotes or the configured account."
  (let ((root (ecim-repository-root directory)))
    (unless root
      (signal 'ecim-error (list (format "Not inside a Git repository: %s"
                                        (abbreviate-file-name
                                         (or directory default-directory))))))
    (or (gethash root ecim-repository--cache)
        (let* ((url (or (ecim--git-output root "remote" "get-url" ecim-remote-name)
                        (signal 'ecim-error
                                (list (format "Repository %s has no remote named %s"
                                              (abbreviate-file-name root)
                                              ecim-remote-name)))))
               (parsed (or (ecim-repository--parse-remote url)
                           ;; Deliberately not echoing URL: it may carry a token.
                           (signal 'ecim-error
                                   (list (format "Cannot parse the %s remote of %s"
                                                 ecim-remote-name
                                                 (abbreviate-file-name root))))))
               (repo (ecim-repo-create
                      :root root
                      :host (plist-get parsed :host)
                      :owner (plist-get parsed :owner)
                      :name (plist-get parsed :name)
                      :account (ecim-repository--account root))))
          (puthash root repo ecim-repository--cache)))))

(defun ecim-repository-current-branch (&optional directory)
  "Return the checked out branch of the repository at DIRECTORY."
  (ecim--git-output (or directory default-directory)
                    "symbolic-ref" "--short" "--quiet" "HEAD"))

(defun ecim-repository-refs (repo)
  "Return branch and tag names known to REPO, for ref completion.
Remote-tracking refs are reduced to their branch name, since that
is what a provider expects when a workflow is dispatched."
  (let* ((root (ecim-repo-root repo))
         (raw (split-string (or (ecim--git-output root "for-each-ref"
                                                  "--format=%(refname:short)"
                                                  "refs/heads" "refs/remotes"
                                                  "refs/tags")
                                "")
                            "\n" t))
         (prefix (concat ecim-remote-name "/"))
         refs)
    (dolist (ref raw)
      (let ((ref (if (string-prefix-p prefix ref)
                     (substring ref (length prefix))
                   ref)))
        (unless (or (string= ref "HEAD") (member ref refs))
          (push ref refs))))
    (nreverse refs)))

;;;###autoload
(defun ecim-repository-invalidate ()
  "Forget cached repository detection results."
  (interactive)
  (clrhash ecim-repository--cache)
  (when (called-interactively-p 'interactive)
    (message "ECIM: repository cache cleared")))

(provide 'ecim-repository)
;;; ecim-repository.el ends here
