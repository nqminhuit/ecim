;;; ecim-tests.el --- Tests for ECIM  -*- lexical-binding: t; -*-

;;; Commentary:

;; Unit tests for the parts of ECIM that do not touch the network:
;; remote parsing, formatting, response header handling and the
;; workflow_dispatch input reader.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ecim-core)
(require 'ecim-repository)
(require 'ecim-auth)
(require 'ecim-github)
(require 'ecim-runs)

;;;; Remote parsing

(ert-deftest ecim-repository-parse-remote-https ()
  (let ((parsed (ecim-repository--parse-remote "https://github.com/owner/repo.git")))
    (should (equal (plist-get parsed :host) "github.com"))
    (should (equal (plist-get parsed :owner) "owner"))
    (should (equal (plist-get parsed :name) "repo"))))

(ert-deftest ecim-repository-parse-remote-without-suffix ()
  (let ((parsed (ecim-repository--parse-remote "https://github.com/owner/repo")))
    (should (equal (plist-get parsed :name) "repo"))))

(ert-deftest ecim-repository-parse-remote-trailing-slash ()
  (let ((parsed (ecim-repository--parse-remote "https://github.com/owner/repo/")))
    (should (equal (plist-get parsed :name) "repo"))))

(ert-deftest ecim-repository-parse-remote-scp ()
  (let ((parsed (ecim-repository--parse-remote "git@github.com:owner/repo.git")))
    (should (equal (plist-get parsed :host) "github.com"))
    (should (equal (plist-get parsed :owner) "owner"))
    (should (equal (plist-get parsed :name) "repo"))))

(ert-deftest ecim-repository-parse-remote-ssh-scheme-with-port ()
  (let ((parsed (ecim-repository--parse-remote "ssh://git@github.com:2222/owner/repo.git")))
    (should (equal (plist-get parsed :host) "github.com"))
    (should (equal (plist-get parsed :owner) "owner"))
    (should (equal (plist-get parsed :name) "repo"))))

(ert-deftest ecim-repository-parse-remote-discards-credentials ()
  "A token in the remote URL must not survive repository parsing.
`ecim-auth' reads it deliberately when authenticating, but the
repository struct is cached, passed around and printed, so the
secret must not travel inside it."
  (let* ((url "https://someone:ghp_notARealToken0000@github.com/owner/repo.git")
         (parsed (ecim-repository--parse-remote url)))
    (should (equal (plist-get parsed :host) "github.com"))
    (should (equal (plist-get parsed :owner) "owner"))
    (should (equal (plist-get parsed :name) "repo"))
    (should-not (string-match-p "ghp_" (format "%S" parsed)))))

(ert-deftest ecim-repository-parse-remote-numeric-owner-is-not-a-port ()
  "In the scp form the colon starts the path, so \"host:123/repo\"
belongs to the organisation 123 and has no port."
  (let ((parsed (ecim-repository--parse-remote "git@github.com:123/repo.git")))
    (should (equal (plist-get parsed :host) "github.com"))
    (should (equal (plist-get parsed :owner) "123"))
    (should (equal (plist-get parsed :name) "repo")))
  ;; A scheme is what allows a port, and it still works.
  (let ((parsed (ecim-repository--parse-remote "ssh://git@github.com:2222/123/repo.git")))
    (should (equal (plist-get parsed :owner) "123"))
    (should (equal (plist-get parsed :name) "repo"))))

(ert-deftest ecim-repository-parse-remote-nested-owner ()
  (let ((parsed (ecim-repository--parse-remote "https://gitlab.com/group/sub/repo.git")))
    (should (equal (plist-get parsed :owner) "group/sub"))
    (should (equal (plist-get parsed :name) "repo"))))

(ert-deftest ecim-repository-parse-remote-uppercase-host ()
  (should (equal (plist-get (ecim-repository--parse-remote "git@GitHub.com:o/r.git") :host)
                 "github.com")))

(ert-deftest ecim-repository-parse-remote-rejects-nonsense ()
  (should-not (ecim-repository--parse-remote "not a url"))
  (should-not (ecim-repository--parse-remote ""))
  (should-not (ecim-repository--parse-remote nil)))

;;;; Loading
;;
;; These must run in a fresh Emacs: the rest of the suite requires
;; ecim-github itself, which would hide exactly the bug being tested.

(defconst ecim-tests--root
  (file-name-directory (or (locate-library "ecim-core") default-directory))
  "Directory the package is loaded from.")

(defun ecim-tests--in-fresh-emacs (form)
  "Evaluate FORM in a bare batch Emacs and return its exit status."
  (call-process (expand-file-name invocation-name invocation-directory)
                nil nil nil "-Q" "--batch" "-L" ecim-tests--root
                "--eval" (prin1-to-string form)))

(ert-deftest ecim-entry-points-load-a-provider-implementation ()
  "`M-x ecim' autoloads the views, not the package as a whole.
The views require the provider interface but no implementation, so
selecting a provider has to pull one in; otherwise the generics
dispatch with no applicable method and the dashboard dies on its
first request."
  (should
   (eq 0 (ecim-tests--in-fresh-emacs
          '(progn
             ;; Exactly what the autoload of `ecim-runs' loads.
             (require 'ecim-runs)
             (let ((repo (ecim-repo-create :root "/tmp/r/" :host "github.com"
                                           :owner "o" :name "r")))
               (unless (eq 'github (ecim-provider-for-repo repo))
                 (kill-emacs 3))
               (unless (featurep 'ecim-github)
                 (kill-emacs 4))
               ;; The real symptom: a generic with nothing to dispatch to.
               (unless (cl-find-method #'ecim-provider-list-runs nil
                                       (list '(eql github) t t t))
                 (kill-emacs 5)))
             (kill-emacs 0))))))

(ert-deftest ecim-every-file-is-loadable-on-its-own ()
  "Each file must pull in what it uses, so load order cannot matter."
  (dolist (feature '(ecim-core ecim-repository ecim-auth ecim-provider
                     ecim-github ecim-ui ecim-logs ecim-artifacts ecim-runs ecim))
    (should (eq 0 (ecim-tests--in-fresh-emacs `(require ',feature))))))

;;;; Authentication

(defmacro ecim-tests--with-remote (url &rest body)
  "Run BODY with the repository remote reported as URL."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'ecim--git-output)
              (lambda (_root &rest args)
                (when (equal args (list "remote" "get-url" "origin")) ,url))))
     ,@body))

(ert-deftest ecim-auth-takes-the-token-from-an-https-remote ()
  (let ((repo (ecim-repo-create :root "/tmp/r/" :host "github.com" :owner "o" :name "r")))
    ;; After a colon anything goes: it is unambiguously the password.
    (ecim-tests--with-remote "https://user:github_pat_ABC123@github.com/o/r.git"
      (should (equal (ecim-auth--from-remote-url repo) "github_pat_ABC123")))
    (ecim-tests--with-remote "https://user:tok%2Fen@github.com/o/r.git"
      (should (equal (ecim-auth--from-remote-url repo) "tok/en")))
    ;; A token on its own, with no user part, is the other common shape.
    (dolist (token '("github_pat_11ABY6JAY0cnC03U7rFPbT"
                     "ghp_16CharsOrMoreHere"
                     "gho_16CharsOrMoreHere"
                     "0123456789abcdef0123456789abcdef01234567"))
      (ecim-tests--with-remote (format "https://%s@github.com/o/r.git" token)
        (should (equal (ecim-auth--from-remote-url repo) token))))))

(ert-deftest ecim-auth-ignores-a-bare-username-in-the-remote ()
  "\"https://alice@github.com/...\" is an ordinary clone whose
credential lives in a Git credential helper.  Sending \"alice\" as a
bearer token would turn a helpful error into a puzzling 401."
  (let ((repo (ecim-repo-create :root "/tmp/r/" :host "github.com" :owner "o" :name "r")))
    (dolist (userinfo '("alice" "some-long-user-name" "nqminhuit"))
      (ecim-tests--with-remote (format "https://%s@github.com/o/r.git" userinfo)
        (should-not (ecim-auth--from-remote-url repo))))))

(ert-deftest ecim-auth-finds-no-token-without-one ()
  (let ((repo (ecim-repo-create :root "/tmp/r/" :host "github.com" :owner "o" :name "r")))
    (dolist (url '("https://github.com/o/r.git"
                   "git@github.com:o/r.git"
                   "ssh://git@github.com/o/r.git"
                   "https://user:@github.com/o/r.git"))
      (ecim-tests--with-remote url
        (should-not (ecim-auth--from-remote-url repo))))))

(ert-deftest ecim-auth-cache-is-per-repository ()
  "Two clones on one host must not share a token.
With no configured login the credential comes from each clone's own
remote, so a host-wide cache key would hand the first repository's
token to every other repository on that host."
  (clrhash ecim-auth--cache)
  (let ((personal (ecim-repo-create :root "/tmp/personal/" :host "github.com"
                                    :owner "me" :name "blog"))
        (work (ecim-repo-create :root "/tmp/work/" :host "github.com"
                                :owner "acme" :name "api")))
    (cl-letf (((symbol-function 'auth-source-search) (lambda (&rest _) nil))
              ((symbol-function 'ecim--git-output)
               (lambda (root &rest _)
                 (format "https://u:github_pat_%s@github.com/o/r.git"
                         (if (equal root "/tmp/personal/") "PERSONALTOKEN" "WORKTOKEN")))))
      (should (equal (ecim-auth-token personal "api.github.com")
                     "github_pat_PERSONALTOKEN"))
      (should (equal (ecim-auth-token work "api.github.com")
                     "github_pat_WORKTOKEN"))
      ;; And the cached values stay distinct on the way back.
      (should (equal (ecim-auth-token personal "api.github.com")
                     "github_pat_PERSONALTOKEN"))))
  (clrhash ecim-auth--cache))

(ert-deftest ecim-auth-error-explains-what-is-required ()
  "An SSH clone with no auth-source entry cannot work; say why."
  (let ((repo (ecim-repo-create :root "/tmp/r/" :host "github.com" :owner "o" :name "r")))
    (clrhash ecim-auth--cache)
    (cl-letf (((symbol-function 'auth-source-search) (lambda (&rest _) nil)))
      (ecim-tests--with-remote "git@github.com:o/r.git"
        (let ((err (should-error (ecim-auth-token repo "api.github.com")
                                 :type 'ecim-auth-error)))
          (should (string-match-p "HTTPS" (cadr err)))
          (should (string-match-p "workflow scope" (cadr err))))))))

(ert-deftest ecim-auth-prefers-a-named-account-over-the-remote-url ()
  "Naming a login is an explicit choice, so auth-source wins."
  (let ((repo (ecim-repo-create :root "/tmp/r/" :host "github.com" :owner "o" :name "r"
                                :account "work")))
    (clrhash ecim-auth--cache)
    (cl-letf (((symbol-function 'auth-source-search)
               (lambda (&rest args)
                 (when (equal (plist-get args :user) "work")
                   (list (list :user "work" :secret "from-auth-source"))))))
      (ecim-tests--with-remote "https://user:from_remote_url@github.com/o/r.git"
        (should (equal (ecim-auth-token repo "api.github.com") "from-auth-source"))))
    (clrhash ecim-auth--cache)))

(ert-deftest ecim-auth-falls-back-to-the-remote-url-for-a-named-account ()
  "A configured login with no entry should not dead-end the lookup."
  (let ((repo (ecim-repo-create :root "/tmp/r/" :host "github.com" :owner "o" :name "r"
                                :account "work")))
    (clrhash ecim-auth--cache)
    (cl-letf (((symbol-function 'auth-source-search) (lambda (&rest _) nil)))
      (ecim-tests--with-remote "https://user:from_remote_url@github.com/o/r.git"
        (should (equal (ecim-auth-token repo "api.github.com") "from_remote_url"))))
    (clrhash ecim-auth--cache)))

;;;; Formatting

(ert-deftest ecim-relative-time-scales ()
  (let ((now (current-time)))
    (should (equal (ecim--relative-time (time-add now -5)) "5s ago"))
    (should (equal (ecim--relative-time (time-add now -120)) "2m ago"))
    (should (equal (ecim--relative-time (time-add now -7200)) "2h ago"))
    (should (equal (ecim--relative-time (time-add now (* -3 86400))) "3d ago"))
    (should (equal (ecim--relative-time nil) ""))))

(ert-deftest ecim-relative-time-far-past-is-a-date ()
  (should (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'"
                          (ecim--relative-time (time-add (current-time) (* -400 86400))))))

(ert-deftest ecim-duration-formats ()
  (let ((start (current-time)))
    (should (equal (ecim--duration start (time-add start 45)) "45s"))
    (should (equal (ecim--duration start (time-add start 125)) "2m05s"))
    (should (equal (ecim--duration start (time-add start 3725)) "1h02m"))
    (should (equal (ecim--duration nil nil) ""))))

(ert-deftest ecim-symbol-normalizes-underscores ()
  (should (eq (ecim--symbol "in_progress") 'in-progress))
  (should (eq (ecim--symbol "TIMED_OUT") 'timed-out))
  (should-not (ecim--symbol nil))
  (should-not (ecim--symbol "")))

(ert-deftest ecim-status-symbol-uses-conclusion-when-completed ()
  (should (equal (substring-no-properties (ecim--status-symbol 'completed 'success)) "✓"))
  (should (equal (substring-no-properties (ecim--status-symbol 'completed 'failure)) "✗"))
  (should (equal (substring-no-properties (ecim--status-symbol 'completed 'cancelled)) "⊘"))
  (should (equal (substring-no-properties (ecim--status-symbol 'in-progress nil)) "⟳"))
  (should (equal (substring-no-properties (ecim--status-symbol 'queued nil)) "○"))
  (should (equal (substring-no-properties (ecim--status-symbol 'completed nil)) "–")))

(ert-deftest ecim-status-symbol-is-faced ()
  (should (eq (get-text-property 0 'face (ecim--status-symbol 'completed 'failure))
              'ecim-failure)))

;;;; Column sizing

(ert-deftest ecim-size-columns-widens-to-fit-data ()
  "A column grows to its widest cell instead of always truncating."
  (with-temp-buffer
    (ecim-runs-mode)
    (setq ecim--base-column-format (copy-sequence tabulated-list-format))
    (let* ((branch "feature/a-fairly-descriptive-branch-name")
           (entries (list (list 'r1 (vector "✓" "CI" "#1" branch "push" "octocat" "2m ago")))))
      (ecim--size-columns entries)
      (should (= (nth 1 (aref tabulated-list-format 3)) (string-width branch)))
      ;; Nothing in this data is wider than the column's own default.
      (should (= (nth 1 (aref tabulated-list-format 1)) 22)))))

(ert-deftest ecim-size-columns-respects-the-cap ()
  "One absurdly long name must not stretch the column past its cap.
`tabulated-list-print-col' still shows it, truncated with its own
ellipsis at render time."
  (with-temp-buffer
    (ecim-runs-mode)
    (setq ecim--base-column-format (copy-sequence tabulated-list-format))
    (let* ((long-name (make-string 80 ?x))
           (entries (list (list 'r1 (vector "✓" long-name "#1" "main" "push" "octocat" "2m")))))
      (ecim--size-columns entries)
      (should (= (nth 1 (aref tabulated-list-format 1)) 50)))))

(ert-deftest ecim-fill-recomputes-widths-instead-of-compounding-them ()
  "A later, narrower refresh must shrink columns back down.
Sizing from whatever `tabulated-list-format' currently holds,
rather than from the mode's original definition, would only ever
grow columns across refreshes and never shrink them."
  (with-temp-buffer
    (ecim-runs-mode)
    (let ((wide (ecim-run-create :id 1 :number 1 :name (make-string 45 ?x)
                                 :status 'completed :conclusion 'success))
          (narrow (ecim-run-create :id 2 :number 2 :name "CI"
                                   :status 'completed :conclusion 'success)))
      (ecim--fill (current-buffer) (list (ecim-runs--entry wide)))
      (should (= (nth 1 (aref tabulated-list-format 1)) 45))
      (ecim--fill (current-buffer) (list (ecim-runs--entry narrow)))
      (should (= (nth 1 (aref tabulated-list-format 1)) 22)))))

;;;; HTTP helpers

(ert-deftest ecim-github-next-page-from-link-header ()
  (let ((link (concat "<https://api.github.com/repositories/1/actions/runs?page=2>; rel=\"next\", "
                      "<https://api.github.com/repositories/1/actions/runs?page=9>; rel=\"last\"")))
    (should (equal (ecim-github--next-page link)
                   "https://api.github.com/repositories/1/actions/runs?page=2"))))

(ert-deftest ecim-github-next-page-absent-on-last-page ()
  (should-not (ecim-github--next-page
               "<https://api.github.com/x?page=1>; rel=\"prev\", <https://api.github.com/x?page=1>; rel=\"first\""))
  (should-not (ecim-github--next-page nil)))

(ert-deftest ecim-github-redirect-target-from-status ()
  "A disabled redirect surfaces as an error carrying the target URL."
  (should (equal (ecim-github--redirect-target
                  '(:error (error http-redirect-limit "https://storage.example/blob")))
                 "https://storage.example/blob"))
  (should-not (ecim-github--redirect-target '(:error (error connection-failed)))))

(ert-deftest ecim-github-error-describes-the-status ()
  "HTTP failures must be reported in GitHub's words, not url.el's.
url.el turns any 4xx into a bare `(error http CODE)', which
renders as \"peculiar error: 404\"."
  (with-temp-buffer
    (insert "HTTP/1.1 404 Not Found\nContent-Type: application/json\n\n")
    (let ((err (ecim-github--error 404 "{\"message\": \"Not Found\"}")))
      (should (eq (car err) 'ecim-http-error))
      (should (string-match-p "Not Found" (nth 1 err)))
      (should (string-match-p "404" (nth 1 err)))))
  (with-temp-buffer
    (insert "HTTP/1.1 401 Unauthorized\n\n")
    (should (string-match-p "token"
                            (nth 1 (ecim-github--error
                                    401 "{\"message\": \"Bad credentials\"}"))))))

(ert-deftest ecim-github-error-names-the-missing-actions-permission ()
  "A 403 is almost always a token without Actions access, so say so."
  (with-temp-buffer
    (insert "HTTP/1.1 403 Forbidden\nx-oauth-scopes: gist, repo\n\n")
    (let ((message (nth 1 (ecim-github--error 403 "{\"message\": \"Forbidden\"}"))))
      (should (string-match-p "read Actions" message))
      (should (string-match-p "workflow scope" message))
      (should (string-match-p "gist, repo" message))))
  (with-temp-buffer
    (insert "HTTP/1.1 403 Forbidden\nx-accepted-github-permissions: actions=read\n\n")
    (should (string-match-p "actions=read" (nth 1 (ecim-github--error 403 "{}"))))))

(ert-deftest ecim-github-error-detects-rate-limiting ()
  (with-temp-buffer
    (insert "HTTP/1.1 403 Forbidden\nx-ratelimit-remaining: 0\nx-ratelimit-reset: 1757000000\n\n")
    (should (string-match-p "rate limit" (nth 1 (ecim-github--error 403 "{}"))))))

(ert-deftest ecim-github-redirect-target-ignores-followed-redirects ()
  "url.el records `:redirect' for redirects it followed itself, and
delivers the final successful response alongside it.  Treating that
as a redirect would discard a good reply and refetch it with no
credentials -- turning a working call into a 401."
  (should-not (ecim-github--redirect-target
               '(:redirect "https://api.github.com/repositories/9/actions/runs")))
  ;; Only a refused redirect is ours to follow.
  (should (equal (ecim-github--redirect-target
                  '(:error (error http-redirect-limit "https://storage.example/blob")))
                 "https://storage.example/blob")))

(ert-deftest ecim-github-stops-following-endless-redirects ()
  (let ((calls 0) reported)
    (cl-letf (((symbol-function 'ecim-auth-token) (lambda (&rest _) "t"))
              ((symbol-function 'url-retrieve)
               (lambda (_url callback args &rest _)
                 (setq calls (1+ calls))
                 (with-temp-buffer
                   (apply callback
                          '(:error (error http-redirect-limit "https://storage/loop"))
                          args)))))
      (ecim-github--fetch "https://storage/loop" "GET" nil nil 'binary
                          #'ignore (lambda (err) (setq reported err))))
    (should (<= calls (1+ ecim-github--max-redirects)))
    (should (string-match-p "redirect" (nth 1 reported)))))

(ert-deftest ecim-github-api-base-distinguishes-enterprise ()
  (let ((repo (ecim-repo-create :host "github.com" :owner "o" :name "r")))
    (should (equal (ecim-github--api-base repo) "https://api.github.com"))
    (should (equal (ecim-github--api-host repo) "api.github.com")))
  (let ((repo (ecim-repo-create :host "git.example.com" :owner "o" :name "r")))
    (should (equal (ecim-github--api-base repo) "https://git.example.com/api/v3"))
    (should (equal (ecim-github--api-host repo) "git.example.com"))))

(ert-deftest ecim-github-url-builds-repository-paths ()
  (let ((repo (ecim-repo-create :host "github.com" :owner "o" :name "r")))
    (should (equal (ecim-github--url repo "/actions/runs")
                   "https://api.github.com/repos/o/r/actions/runs"))
    (should (equal (ecim-github--url repo "/actions/runs" '(("branch" . "main")))
                   "https://api.github.com/repos/o/r/actions/runs?branch=main"))
    ;; Nil values are dropped rather than sent as "nil".
    (should (equal (ecim-github--url repo "/actions/runs" '(("branch" . nil) ("per_page" . 5)))
                   "https://api.github.com/repos/o/r/actions/runs?per_page=5"))
    (should (equal (ecim-github--url repo "/repos/other/repo/contents/a.yml")
                   "https://api.github.com/repos/other/repo/contents/a.yml"))))

(ert-deftest ecim-github-url-escapes-parameters ()
  (let ((repo (ecim-repo-create :host "github.com" :owner "o" :name "r")))
    (should (equal (ecim-github--url repo "/actions/runs" '(("branch" . "feature/a b")))
                   "https://api.github.com/repos/o/r/actions/runs?branch=feature%2Fa%20b"))))

;;;; Pickers

(ert-deftest ecim-runs-pick-job-refuses-an-empty-answer ()
  "`completing-read' returns the empty string on a bare RET even with
REQUIRE-MATCH, which used to reach `ecim-job-name' with nil."
  (let ((jobs (list (ecim-job-create :id 1 :name "build")
                    (ecim-job-create :id 2 :name "test"))))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "")))
      (should-error (ecim-runs--pick-job ecim-tests--repo jobs) :type 'user-error))
    (let (shown)
      (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "test"))
                ((symbol-function 'ecim-show-job-log)
                 (lambda (_repo job) (setq shown (ecim-job-name job)))))
        (ecim-runs--pick-job ecim-tests--repo jobs)
        (should (equal shown "test"))))))

(ert-deftest ecim-runs-read-input-retries-with-the-same-question ()
  "A required choice input must be asked as a choice on retry, not as
free text, or a value the workflow rejects can be submitted."
  (let* ((input (ecim-input-create :name "environment" :required t :type 'choice
                                   :options '("staging" "production")))
         (asked nil)
         (answers '("" "production")))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt collection &rest _)
                 (push collection asked)
                 (pop answers)))
              ((symbol-function 'read-string)
               (lambda (&rest _) (push 'read-string asked) "typo")))
      (should (equal (ecim-runs--read-input input) "production")))
    (should (equal asked '(("staging" "production") ("staging" "production"))))))

;;;; Conversion

(ert-deftest ecim-github-run-conversion ()
  (let* ((data '((id . 42) (run_number . 1842) (name . "CI") (workflow_id . 7)
                 (status . "in_progress") (conclusion . nil) (head_branch . "main")
                 (event . "push") (actor . ((login . "octocat")))
                 (head_sha . "abc123") (display_title . "Fix the thing")
                 (created_at . "2026-09-07T10:00:00Z")
                 (updated_at . "2026-09-07T10:05:00Z")
                 (html_url . "https://github.com/o/r/actions/runs/42")))
         (run (ecim-github--run data)))
    (should (eq (ecim-run-status run) 'in-progress))
    (should-not (ecim-run-conclusion run))
    (should (ecim-run-active-p run))
    (should (equal (ecim-run-actor run) "octocat"))
    (should (equal (ecim-run-number run) 1842))
    (should (ecim-run-created-at run))))

(ert-deftest ecim-github-run-conversion-completed ()
  (let ((run (ecim-github--run '((id . 1) (status . "completed") (conclusion . "timed_out")))))
    (should (eq (ecim-run-conclusion run) 'timed-out))
    (should-not (ecim-run-active-p run))))

;;;; Request building
;;
;; The write paths cannot be exercised against a repository we do not
;; own, so the transport is stubbed and the request itself inspected.

(defvar ecim-tests--repo
  (ecim-repo-create :root "/tmp/r/" :host "github.com" :owner "o" :name "r"))

(defmacro ecim-tests--capturing (place &rest body)
  "Run BODY with the HTTP layer stubbed, recording requests into PLACE.
Each entry is (URL METHOD BODY)."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'ecim-auth-token) (lambda (&rest _) "test-token"))
             ((symbol-function 'ecim-github--fetch)
              (lambda (url method _headers data _reader callback _errback)
                (push (list url method
                            (when data
                              (json-parse-string (decode-coding-string data 'utf-8)
                                                 :object-type 'alist)))
                      ,place)
                (funcall callback nil nil))))
     ,@body
     (setq ,place (nreverse ,place))))

(ert-deftest ecim-github-trigger-builds-a-dispatch-request ()
  (let ((requests nil)
        (workflow (ecim-workflow-create :id 99 :name "Release" :path ".github/workflows/r.yml")))
    (cl-letf (((symbol-function 'ecim-github--find-dispatched-run)
               (lambda (_repo _wf _ref _after callback _delays) (funcall callback nil))))
      (ecim-tests--capturing requests
        (ecim-provider-trigger-workflow
         'github ecim-tests--repo workflow "main"
         '(("version" . "1.2.3") ("dry-run" . "true"))
         #'ignore)))
    (let ((request (car requests)))
      (should (equal (nth 0 request)
                     "https://api.github.com/repos/o/r/actions/workflows/99/dispatches"))
      (should (equal (nth 1 request) "POST"))
      (should (equal (alist-get 'ref (nth 2 request)) "main"))
      (let ((inputs (alist-get 'inputs (nth 2 request))))
        (should (equal (alist-get 'version inputs) "1.2.3"))
        (should (equal (alist-get 'dry-run inputs) "true"))))))

(ert-deftest ecim-github-trigger-omits-empty-inputs ()
  (let ((requests nil)
        (workflow (ecim-workflow-create :id 5 :name "CI")))
    (cl-letf (((symbol-function 'ecim-github--find-dispatched-run)
               (lambda (_repo _wf _ref _after callback _delays) (funcall callback nil))))
      (ecim-tests--capturing requests
        (ecim-provider-trigger-workflow 'github ecim-tests--repo workflow "v1.0" nil #'ignore)))
    (should (equal (alist-get 'ref (nth 2 (car requests))) "v1.0"))
    (should-not (assq 'inputs (nth 2 (car requests))))))

(ert-deftest ecim-github-cancel-and-rerun-endpoints ()
  (let ((requests nil))
    (ecim-tests--capturing requests
      (ecim-provider-cancel-run 'github ecim-tests--repo 42 #'ignore)
      (ecim-provider-rerun-run 'github ecim-tests--repo 42 nil #'ignore)
      (ecim-provider-rerun-run 'github ecim-tests--repo 42 t #'ignore)
      (ecim-provider-rerun-job 'github ecim-tests--repo 7 #'ignore))
    (should (equal (mapcar (lambda (r) (nth 1 r)) requests)
                   '("POST" "POST" "POST" "POST")))
    (should (equal (mapcar (lambda (r) (nth 0 r)) requests)
                   '("https://api.github.com/repos/o/r/actions/runs/42/cancel"
                     "https://api.github.com/repos/o/r/actions/runs/42/rerun"
                     "https://api.github.com/repos/o/r/actions/runs/42/rerun-failed-jobs"
                     "https://api.github.com/repos/o/r/actions/jobs/7/rerun")))))

(ert-deftest ecim-github-pagination-concatenates-envelopes ()
  "Paginated listings must merge the wrapped lists, not shadow them."
  (let ((pages '(("https://api.github.com/repos/o/r/actions/workflows?per_page=100"
                  . (((workflows . (((id . 1) (name . "one"))))) . "https://next/2"))
                 ("https://next/2"
                  . (((workflows . (((id . 2) (name . "two"))))) . nil))))
        result)
    (cl-letf (((symbol-function 'ecim-auth-token) (lambda (&rest _) "test-token"))
              ((symbol-function 'ecim-github--fetch)
               (lambda (url _method _headers _data _reader callback _errback)
                 (let ((page (cdr (assoc url pages))))
                   (should page)
                   (funcall callback (car page) (cdr page))))))
      (ecim-provider-list-workflows 'github ecim-tests--repo
                                    (lambda (ws) (setq result ws))))
    (should (equal (mapcar #'ecim-workflow-name result) '("one" "two")))))

(ert-deftest ecim-github-pagination-stops-at-the-page-limit ()
  (let ((calls 0) result)
    (cl-letf (((symbol-function 'ecim-auth-token) (lambda (&rest _) "test-token"))
              ((symbol-function 'ecim-github--fetch)
               (lambda (_url _method _headers _data _reader callback _errback)
                 (setq calls (1+ calls))
                 (funcall callback '((workflows . (((id . 1) (name . "w"))))) "https://next"))))
      (let ((ecim-max-pages 3))
        (ecim-provider-list-workflows 'github ecim-tests--repo
                                      (lambda (ws) (setq result ws)))))
    (should (= calls 3))
    (should (= (length result) 3))))

;;;; workflow_dispatch inputs

(defconst ecim-tests--workflow-yaml "\
name: Release
on:
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      version:
        description: 'Version to release'
        required: true
        type: string
      environment:
        description: Target environment
        required: false
        default: staging
        type: choice
        options:
          - staging
          - production
      dry-run:
        description: Skip publishing
        type: boolean
        default: false
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
"
  "A workflow file exercising every kind of dispatch input.")

(ert-deftest ecim-logs-decorate-strips-timestamps-and-bom ()
  "Logs arrive with a leading BOM, which hid the first timestamp."
  (require 'ecim-logs)
  (with-temp-buffer
    (insert (string-remove-prefix
             "\ufeff"
             "\ufeff2026-09-07T04:48:03.0477710Z Current runner version: '2.337.0'\n"))
    (insert "2026-09-07T04:48:03.0500000Z ##[group]Run actions/checkout@v4\n")
    (insert "2026-09-07T04:48:03.0600000Z ##[error]it broke\n")
    (insert "2026-09-07T04:48:03.0700000Z ##[endgroup]\n")
    (let ((ecim-logs-strip-timestamps t))
      (ecim-logs--decorate))
    (let ((text (buffer-string)))
      (should (string-prefix-p "Current runner version" text))
      (should-not (string-match-p "2026-09-07T" text))
      (should (string-match-p "▸ Run actions/checkout@v4" text))
      (should (string-match-p "error: it broke" text))
      (should-not (string-match-p "##\\[" text)))
    (goto-char (point-min))
    (should (get-text-property (next-single-property-change (point) 'ecim-step)
                               'ecim-step))))

(ert-deftest ecim-github-dispatch-inputs-parsing ()
  (let ((inputs (ecim-github--dispatch-inputs ecim-tests--workflow-yaml)))
    (should (= (length inputs) 3))
    (should (equal (mapcar #'ecim-input-name inputs)
                   '("version" "environment" "dry-run")))
    (let ((version (nth 0 inputs))
          (environment (nth 1 inputs))
          (dry-run (nth 2 inputs)))
      (should (ecim-input-required version))
      (should (equal (ecim-input-description version) "Version to release"))
      (should (eq (ecim-input-type version) 'string))
      (should-not (ecim-input-required environment))
      (should (eq (ecim-input-type environment) 'choice))
      (should (equal (ecim-input-options environment) '("staging" "production")))
      (should (equal (ecim-input-default environment) "staging"))
      (should (eq (ecim-input-type dry-run) 'boolean))
      (should (equal (ecim-input-default dry-run) "false")))))

(ert-deftest ecim-github-dispatch-inputs-absent ()
  "A workflow without manual inputs yields nothing to prompt for."
  (should-not (ecim-github--dispatch-inputs "name: CI\non:\n  push:\njobs:\n  a:\n    runs-on: x\n"))
  (should-not (ecim-github--dispatch-inputs "on: [push, workflow_dispatch]\n"))
  (should-not (ecim-github--dispatch-inputs "on:\n  workflow_dispatch:\n")))

(ert-deftest ecim-github-dispatch-inputs-survive-comments ()
  (let ((inputs (ecim-github--dispatch-inputs "\
on:
  workflow_dispatch:   # manual only
    inputs:
      # which build to ship
      tag:
        description: Tag
        required: true
")))
    (should (= (length inputs) 1))
    (should (equal (ecim-input-name (car inputs)) "tag"))
    (should (ecim-input-required (car inputs)))))

(ert-deftest ecim-github-dispatch-inputs-keep-hash-inside-quotes ()
  (let ((inputs (ecim-github--dispatch-inputs "\
on:
  workflow_dispatch:
    inputs:
      note:
        default: \"issue #12\"
")))
    (should (equal (ecim-input-default (car inputs)) "issue #12"))))

(ert-deftest ecim-github-dispatch-inputs-tolerate-garbage ()
  "Unparseable input yields nil rather than an error, so the caller
can fall back to asking for values by hand."
  (should-not (ecim-github--dispatch-inputs ""))
  (should-not (ecim-github--dispatch-inputs "\0\0\0 not yaml at all")))

(provide 'ecim-tests)
;;; ecim-tests.el ends here
