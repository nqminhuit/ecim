;;; ecim-auth.el --- Repository-aware authentication for ECIM  -*- lexical-binding: t; -*-

;;; Commentary:

;; ECIM authenticates over HTTPS.  The token normally comes from the
;; repository's own remote URL in .git/config, which makes it
;; repository-local by construction: a personal clone and a work clone
;; carry different credentials with no further configuration.
;;
;; The lookup order is:
;;
;;   1. `auth-source' for the login configured for this repository, if
;;      any (`ecim.account' in the Git config, or the `ecim-account'
;;      directory-local variable).  Naming a login is an explicit
;;      choice, so it wins.
;;   2. the token embedded in the HTTPS remote URL.
;;   3. `auth-source' for the API host, then the web host.
;;
;; Two consequences, and they are deliberate:
;;
;; * An SSH remote carries no token, so a repository cloned over SSH
;;   needs an `auth-source' entry or it cannot be used at all.
;; * The token must be allowed to read Actions -- the `workflow' scope
;;   on a classic token, or the Actions permission on a fine-grained
;;   one.  A token minted only for pushing will authenticate and then
;;   be refused by every Actions endpoint; `ecim-github--error' says so
;;   in as many words.
;;
;; Anything else raises `ecim-auth-error' rather than failing later in
;; a request.

;;; Code:

(require 'auth-source)
(require 'url-util)
(require 'ecim-core)
(require 'ecim-repository)

(defcustom ecim-auth-remember-account t
  "Whether to offer to record the chosen login in the Git config.
When several `auth-source' entries match a host, ECIM asks which
login to use; recording the answer under `ecim.account' means the
question is asked once per repository."
  :type 'boolean
  :group 'ecim)

(defvar ecim-auth--cache (make-hash-table :test #'equal)
  "Cache of resolved tokens, keyed by (HOST LOGIN REPOSITORY-ROOT).")

(defun ecim-auth--from-auth-source (hosts login)
  "Search HOSTS in `auth-source' for LOGIN and return (LOGIN . TOKEN).
LOGIN may be nil, in which case the user is asked to choose when
more than one entry matches."
  (let ((found (auth-source-search :host hosts
                                   :user login
                                   :max 10
                                   :require '(:secret))))
    (when found
      (let ((entry (if (cdr found)
                       (let* ((users (delq nil (mapcar (lambda (e) (plist-get e :user)) found)))
                              (choice (completing-read
                                       (format "ECIM: several logins for %s, use: "
                                               (if (listp hosts) (car hosts) hosts))
                                       users nil t)))
                         (seq-find (lambda (e) (equal (plist-get e :user) choice)) found))
                     (car found))))
        (when entry
          (let ((secret (plist-get entry :secret)))
            (cons (plist-get entry :user)
                  (if (functionp secret) (funcall secret) secret))))))))

(defconst ecim-auth--token-regexp
  "\\`\\(gh[posru]_[A-Za-z0-9]\\{8,\\}\\|github_pat_[A-Za-z0-9_]\\{8,\\}\\|[0-9a-f]\\{40\\}\\)\\'"
  "Shape of a GitHub token, used to tell one from a plain username.
The prefix carries the weight here: a GitHub login may contain only
letters, digits and hyphens, so nothing with an underscore in it is
a username.")

(defun ecim-auth--from-remote-url (repo)
  "Return the token embedded in the HTTPS remote of REPO, or nil.
Both \"https://TOKEN@host/...\" and \"https://user:TOKEN@host/...\"
are recognised.  Userinfo without a colon is only accepted when it
looks like a token: \"https://alice@host/...\" is an ordinary
HTTPS clone whose credential lives in a Git credential helper, and
sending \"alice\" as a bearer token would replace a helpful error
with a puzzling 401.  The URL is read afresh rather than kept in
the repository struct, so the secret does not travel with it."
  (let ((url (ecim--git-output (ecim-repo-root repo)
                               "remote" "get-url" ecim-remote-name)))
    (when (and url (string-match "\\`https?://\\([^/@]*\\)@" url))
      (let* ((userinfo (match-string 1 url))
             (colon (string-match ":" userinfo))
             (token (url-unhex-string
                     (if colon (substring userinfo (1+ colon)) userinfo))))
        (when (and (not (string-empty-p token))
                   (or colon (string-match-p ecim-auth--token-regexp token)))
          token)))))

(defun ecim-auth--remember (repo login)
  "Offer to store LOGIN as the account for REPO."
  (when (and ecim-auth-remember-account login
             (not (ecim-repo-account repo))
             (y-or-n-p (format "ECIM: always use %s for %s? "
                               login (ecim-repo-slug repo))))
    (ecim--git-output (ecim-repo-root repo) "config" "ecim.account" login)
    (setf (ecim-repo-account repo) login)))

(defun ecim-auth-token (repo &optional api-host)
  "Return the API token to use for REPO.
API-HOST is the host `auth-source' entries are most likely keyed
by; the repository host is tried as well.  Signals `ecim-auth-error'
when no token can be found."
  (let* ((host (ecim-repo-host repo))
         (api-host (or api-host host))
         (login (ecim-repo-account repo))
         ;; The repository has to be part of the key: with no configured
         ;; login the token comes from this clone's own remote, so a
         ;; host-wide key would hand the first repository's credential
         ;; to every other repository on the same host.
         (key (list api-host login (ecim-repo-root repo))))
    (or (gethash key ecim-auth--cache)
        (let ((pair (or (and login (ecim-auth--from-auth-source (list api-host host) login))
                        (let ((token (ecim-auth--from-remote-url repo)))
                          (and token (cons login token)))
                        (and (null login)
                             (ecim-auth--from-auth-source (list api-host host) nil)))))
          (unless (and pair (cdr pair))
            (signal 'ecim-auth-error
                    (list (format (concat "No API token for %s.  ECIM authenticates over "
                                          "HTTPS: clone with a remote URL carrying a token "
                                          "that may read Actions (the workflow scope), or "
                                          "add an auth-source entry for %s%s")
                                  (ecim-repo-slug repo) api-host
                                  (if login (format " with login %s" login) "")))))
          (unless login (ecim-auth--remember repo (car pair)))
          (puthash key (cdr pair) ecim-auth--cache)
          (cdr pair)))))

;;;###autoload
(defun ecim-auth-forget ()
  "Discard cached tokens so they are looked up again."
  (interactive)
  (clrhash ecim-auth--cache)
  (message "ECIM: cached credentials cleared"))

(provide 'ecim-auth)
;;; ecim-auth.el ends here
