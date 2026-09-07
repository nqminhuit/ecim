;;; ecim-github.el --- GitHub Actions provider for ECIM  -*- lexical-binding: t; -*-

;;; Commentary:

;; Everything GitHub-specific lives here: REST paths, JSON field
;; names, status vocabulary and pagination.  The rest of ECIM only
;; sees the core structs produced by the converters below.
;;
;; Transport is `url.el'.  Two details are worth knowing:
;;
;; * Log and artifact endpoints answer 302 with a signed storage URL
;;   that rejects requests carrying an Authorization header.  Those
;;   requests are therefore made with redirects disabled, and the
;;   redirect target is fetched again without credentials.
;;
;; * List endpoints paginate through the Link header; ECIM follows
;;   `rel="next"' up to `ecim-max-pages' pages.

;;; Code:

(require 'cl-lib)
(require 'url)
(require 'url-http)
(require 'url-util)
(require 'mail-utils)
(require 'ecim-core)
(require 'ecim-auth)
(require 'ecim-provider)
(require 'ecim-repository)

(defcustom ecim-max-pages 5
  "Maximum number of pages ECIM follows when a listing is paginated."
  :type 'integer
  :group 'ecim)

(defcustom ecim-runs-limit 50
  "Number of workflow runs fetched for the dashboard."
  :type 'integer
  :group 'ecim)

(defconst ecim-github--user-agent "ecim.el"
  "User agent sent with every request.")

(defconst ecim-github--api-version "2022-11-28"
  "Value of the X-GitHub-Api-Version header.")

;;;; URLs and headers

(defun ecim-github--api-host (repo)
  "Return the API host serving REPO."
  (let ((host (ecim-repo-host repo)))
    (if (string= host "github.com") "api.github.com" host)))

(defun ecim-github--api-base (repo)
  "Return the API root URL for REPO."
  (let ((host (ecim-repo-host repo)))
    (if (string= host "github.com")
        "https://api.github.com"
      (format "https://%s/api/v3" host))))

(defun ecim-github--query (params)
  "Encode PARAMS, an alist, as a query string.  Nil values are dropped."
  (mapconcat (lambda (cell)
               (format "%s=%s"
                       (url-hexify-string (format "%s" (car cell)))
                       (url-hexify-string (format "%s" (cdr cell)))))
             (seq-filter #'cdr params)
             "&"))

(defun ecim-github--url (repo path &optional params)
  "Return the absolute URL for PATH in REPO, with optional PARAMS.
PATH starting with \"/repos\" is used as is; anything else is
taken to be relative to the repository."
  (let* ((path (if (string-prefix-p "/repos" path)
                   path
                 (format "/repos/%s/%s%s" (ecim-repo-owner repo) (ecim-repo-name repo) path)))
         (query (and params (ecim-github--query params))))
    (concat (ecim-github--api-base repo) path
            (unless (or (null query) (string-empty-p query)) (concat "?" query)))))

(defun ecim-github--headers (repo reader data)
  "Return request headers for REPO given READER and DATA."
  (append
   (list (cons "Accept" (if (eq reader 'json) "application/vnd.github+json" "*/*"))
         (cons "X-GitHub-Api-Version" ecim-github--api-version)
         (cons "User-Agent" ecim-github--user-agent)
         (cons "Authorization"
               (concat "Bearer " (ecim-auth-token repo (ecim-github--api-host repo)))))
   (when data (list (cons "Content-Type" "application/json")))))

;;;; Response handling

(defun ecim-github--body-start ()
  "Return the position at which the response body begins."
  (if (and (boundp 'url-http-end-of-headers) url-http-end-of-headers)
      (min (point-max) (1+ (marker-position url-http-end-of-headers)))
    (goto-char (point-min))
    (if (re-search-forward "^\r?$" nil t)
        (min (point-max) (1+ (point)))
      (point-min))))

(defun ecim-github--next-page (link)
  "Return the URL of the next page described by the LINK header, if any."
  (when link
    (let ((next nil))
      (dolist (part (split-string link "," t "[ \t\n]+") next)
        (when (and (null next)
                   (string-match "\\`<\\([^>]+\\)>.*rel=[\"']?next[\"']?" part))
          (setq next (match-string 1 part)))))))

(defun ecim-github--error (status body)
  "Return an error object describing HTTP STATUS with BODY."
  (let* ((detail (and body
                      (ignore-errors
                        (alist-get 'message (json-parse-string body :object-type 'alist)))))
         (rate-limited (and (memq status '(403 429))
                            (equal (mail-fetch-field "x-ratelimit-remaining") "0"))))
    (list 'ecim-http-error
          (cond
           (rate-limited
            (let ((reset (mail-fetch-field "x-ratelimit-reset")))
              (format "API rate limit exceeded%s"
                      (if reset
                          (format ", resets at %s"
                                  (format-time-string
                                   "%H:%M" (seconds-to-time (string-to-number reset))))
                        ""))))
           ((eq status 401)
            (format "%s (HTTP 401) -- the token for this repository is not valid"
                    (or detail "Not authorized")))
           ((eq status 403)
            ;; A token minted only for pushing authenticates happily and
            ;; is then refused here, so name the missing permission
            ;; rather than reporting a bare "Forbidden".
            (let ((needed (mail-fetch-field "x-accepted-github-permissions"))
                  (granted (mail-fetch-field "x-oauth-scopes")))
              (format "%s (HTTP 403) -- the token must be allowed to read Actions%s%s"
                      (or detail "Forbidden")
                      (if needed (format ", which needs %s" needed)
                        " (the workflow scope)")
                      (if granted (format "; this token has: %s" granted) ""))))
           ((eq status 404)
            (format "%s (HTTP 404)" (or detail "Not found")))
           (t (format "%s (HTTP %s)" (or detail "Request failed") status))))))

(defun ecim-github--read-body (reader)
  "Return the response body of the current buffer as decided by READER."
  (let ((start (ecim-github--body-start)))
    (pcase reader
      ('none nil)
      ('binary (set-buffer-multibyte nil)
               (buffer-substring-no-properties start (point-max)))
      (_ (let ((text (string-remove-prefix
                      "\ufeff"
                      (decode-coding-string
                       (buffer-substring-no-properties start (point-max))
                       'utf-8))))
           (if (eq reader 'text)
               text
             (unless (string-empty-p (string-trim text))
               (json-parse-string text
                                  :object-type 'alist
                                  :array-type 'list
                                  :null-object nil
                                  :false-object nil))))))))

(defun ecim-github--redirect-target (status)
  "Return the redirect URL ECIM must follow itself, if STATUS is one.
Only a refused redirect counts.  STATUS also carries `:redirect'
for redirects url.el followed on our behalf, and the response that
comes with it is the final, successful one -- treating that as a
redirect would throw a good reply away and refetch it without
credentials."
  (let ((err (plist-get status :error)))
    (and (consp err) (eq (nth 1 err) 'http-redirect-limit) (nth 2 err))))

(defconst ecim-github--max-redirects 3
  "How many storage redirects ECIM follows by hand before giving up.")

(defun ecim-github--fetch (url method headers data reader callback errback &optional depth)
  "Send DATA to URL with METHOD and HEADERS, reading the reply with READER.
CALLBACK receives the body and the URL of the next page, if any.
Errors, including non-2xx responses, go to ERRBACK.  DEPTH counts
the redirects already followed by hand."
  (condition-case err
      (let ((url-request-method method)
            (url-request-extra-headers headers)
            (url-request-data data)
            ;; Signed storage URLs reject an Authorization header, so
            ;; redirects on these readers are followed by hand below.
            (url-max-redirections (if (memq reader '(text binary)) 0 url-max-redirections)))
        (url-retrieve url #'ecim-github--handle
                      (list reader callback errback (or depth 0)) t t))
    (error (funcall errback err))))

(defun ecim-github--handle (status reader callback errback depth)
  "Dispatch on STATUS for a request read with READER.
DEPTH is the number of redirects already followed by hand.  Calls
CALLBACK or ERRBACK, then disposes of the response buffer."
  (let ((buffer (current-buffer)))
    (unwind-protect
        (let ((redirect (ecim-github--redirect-target status))
              (error-info (plist-get status :error)))
          (cond
           ;; Follow the storage redirect without credentials.
           (redirect
            (if (>= depth ecim-github--max-redirects)
                (funcall errback
                         (list 'ecim-http-error
                               (format "Gave up after %d redirects"
                                       ecim-github--max-redirects)))
              (ecim-github--fetch redirect "GET" nil nil reader callback errback
                                  (1+ depth))))
           (t
            (let ((code (and (boundp 'url-http-response-status) url-http-response-status)))
              (cond
               ((and (integerp code) (<= 200 code) (< code 300))
                (let ((next (ecim-github--next-page (mail-fetch-field "link")))
                      (body (ecim-github--read-body reader)))
                  (funcall callback body next)))
               ;; url.el reports any 4xx or 5xx as a bare `(error http CODE)',
               ;; which says nothing useful; describe it ourselves instead and
               ;; keep url.el's object only for transport failures.
               ((integerp code)
                (funcall errback
                         (ecim-github--error code (ignore-errors
                                                    (ecim-github--read-body 'text)))))
               (t (funcall errback (or error-info
                                       (list 'ecim-http-error "No response")))))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(cl-defun ecim-github--request (repo path &key (method "GET") params data reader
                                     collect paginate callback errback)
  "Request PATH within REPO and pass the result to CALLBACK.
METHOD defaults to GET.  PARAMS is a query alist and DATA a Lisp
object serialized as the JSON request body.  READER is one of
`json' (default), `text', `binary' or `none'.  COLLECT names the
key holding the list of interest inside GitHub's response
envelope; with PAGINATE, the Link header is followed and those
lists are concatenated."
  (let ((errback (or errback #'ecim--report-error))
        (reader (or reader 'json))
        (callback (or callback #'ignore)))
    (condition-case err
        (ecim-github--request-page
         repo (ecim-github--url repo path params) method data reader collect paginate
         callback errback nil 1)
      (error (funcall errback err)))))

(defun ecim-github--request-page (repo url method data reader collect paginate
                                       callback errback acc page)
  "Fetch one page of URL from REPO and recurse while pages remain.
METHOD, DATA, READER, COLLECT and PAGINATE are as in
`ecim-github--request', CALLBACK and ERRBACK receive the outcome,
ACC holds the results gathered so far and PAGE counts the request."
  (ecim-github--fetch
   url method
   (ecim-github--headers repo reader data)
   (when data (encode-coding-string (json-serialize data) 'utf-8))
   reader
   (lambda (body next)
     ;; Listings arrive wrapped in an envelope; unwrap before
     ;; accumulating, or pages would simply shadow one another.
     (let* ((body (if collect (alist-get collect body) body))
            (acc (if paginate (append acc body) body)))
       (if (and paginate next (< page ecim-max-pages))
           (ecim-github--request-page repo next method data reader collect paginate
                                      callback errback acc (1+ page))
         (funcall callback acc))))
   errback))

;;;; JSON to core structs

(defun ecim-github--workflow (data)
  "Convert workflow DATA into an `ecim-workflow'."
  (ecim-workflow-create
   :id (alist-get 'id data)
   :name (alist-get 'name data)
   :path (alist-get 'path data)
   :state (ecim--symbol (alist-get 'state data))
   :url (alist-get 'html_url data)))

(defun ecim-github--run (data)
  "Convert run DATA into an `ecim-run'."
  (ecim-run-create
   :id (alist-get 'id data)
   :number (alist-get 'run_number data)
   :name (or (alist-get 'name data) (alist-get 'display_title data))
   :workflow-id (alist-get 'workflow_id data)
   :status (ecim--symbol (alist-get 'status data))
   :conclusion (ecim--symbol (alist-get 'conclusion data))
   :branch (alist-get 'head_branch data)
   :event (alist-get 'event data)
   :actor (alist-get 'login (alist-get 'actor data))
   :sha (alist-get 'head_sha data)
   :title (alist-get 'display_title data)
   :created-at (ecim--parse-time (alist-get 'created_at data))
   :updated-at (ecim--parse-time (alist-get 'updated_at data))
   :url (alist-get 'html_url data)))

(defun ecim-github--job (data)
  "Convert job DATA into an `ecim-job'."
  (ecim-job-create
   :id (alist-get 'id data)
   :run-id (alist-get 'run_id data)
   :name (alist-get 'name data)
   :status (ecim--symbol (alist-get 'status data))
   :conclusion (ecim--symbol (alist-get 'conclusion data))
   :started-at (ecim--parse-time (alist-get 'started_at data))
   :completed-at (ecim--parse-time (alist-get 'completed_at data))
   :url (alist-get 'html_url data)))

(defun ecim-github--artifact (data)
  "Convert artifact DATA into an `ecim-artifact'."
  (ecim-artifact-create
   :id (alist-get 'id data)
   :name (alist-get 'name data)
   :size (alist-get 'size_in_bytes data)
   :expired (eq t (alist-get 'expired data))
   :created-at (ecim--parse-time (alist-get 'created_at data))
   :expires-at (ecim--parse-time (alist-get 'expires_at data))))

;;;; Provider methods

(cl-defmethod ecim-provider-list-workflows ((_p (eql github)) repo callback &optional errback)
  "List the workflows of REPO from /actions/workflows.
PROVIDER is `github'; CALLBACK and ERRBACK receive the outcome."
  (ecim-github--request
   repo "/actions/workflows"
   :params '(("per_page" . 100))
   :collect 'workflows :paginate t
   :callback (lambda (body)
               (funcall callback (mapcar #'ecim-github--workflow body)))
   :errback errback))

(cl-defmethod ecim-provider-list-runs ((_p (eql github)) repo query callback &optional errback)
  "List runs of REPO matching QUERY from /actions/runs.
CALLBACK and ERRBACK receive the outcome."
  (let* ((workflow-id (plist-get query :workflow-id))
         (limit (or (plist-get query :limit) ecim-runs-limit))
         (path (if workflow-id
                   (format "/actions/workflows/%s/runs" workflow-id)
                 "/actions/runs")))
    (ecim-github--request
     repo path
     :params `(("per_page" . ,(min limit 100))
               ("branch" . ,(plist-get query :branch))
               ("event" . ,(plist-get query :event))
               ("status" . ,(plist-get query :status)))
     :collect 'workflow_runs
     ;; One page covers any limit up to 100; only page beyond that, so
     ;; the common case stays a single request.
     :paginate (> limit 100)
     :callback (lambda (body)
                 (funcall callback
                          (seq-take (mapcar #'ecim-github--run body) limit)))
     :errback errback)))

(cl-defmethod ecim-provider-get-run ((_p (eql github)) repo run-id callback &optional errback)
  "Fetch RUN-ID of REPO from /actions/runs.
CALLBACK and ERRBACK receive the outcome."
  (ecim-github--request
   repo (format "/actions/runs/%s" run-id)
   :callback (lambda (body) (funcall callback (ecim-github--run body)))
   :errback errback))

(cl-defmethod ecim-provider-list-jobs ((_p (eql github)) repo run-id callback &optional errback)
  "List the jobs of RUN-ID in REPO from /actions/runs/ID/jobs.
CALLBACK and ERRBACK receive the outcome."
  (ecim-github--request
   repo (format "/actions/runs/%s/jobs" run-id)
   :params '(("per_page" . 100))
   :collect 'jobs :paginate t
   :callback (lambda (body)
               (funcall callback (mapcar #'ecim-github--job body)))
   :errback errback))

(cl-defmethod ecim-provider-get-job-log ((_p (eql github)) repo job-id callback &optional errback)
  "Fetch the log of JOB-ID in REPO from /actions/jobs/ID/logs.
The endpoint redirects to storage, so the reply is read as text.
CALLBACK and ERRBACK receive the outcome."
  (ecim-github--request
   repo (format "/actions/jobs/%s/logs" job-id)
   :reader 'text
   :callback callback
   :errback errback))

(cl-defmethod ecim-provider-list-artifacts ((_p (eql github)) repo run-id callback &optional errback)
  "List the artifacts of RUN-ID in REPO from /actions/runs/ID/artifacts.
CALLBACK and ERRBACK receive the outcome."
  (ecim-github--request
   repo (format "/actions/runs/%s/artifacts" run-id)
   :params '(("per_page" . 100))
   :collect 'artifacts :paginate t
   :callback (lambda (body)
               (funcall callback (mapcar #'ecim-github--artifact body)))
   :errback errback))

(cl-defmethod ecim-provider-download-artifact ((_p (eql github)) repo artifact destination
                                               callback &optional errback)
  "Write ARTIFACT of REPO to DESTINATION as the zip archive GitHub returns.
CALLBACK and ERRBACK receive the outcome."
  (ecim-github--request
   repo (format "/actions/artifacts/%s/zip" (ecim-artifact-id artifact))
   :reader 'binary
   :callback (lambda (body)
               (let ((coding-system-for-write 'binary))
                 (make-directory (file-name-directory destination) t)
                 (write-region body nil destination nil 'silent))
               (funcall callback destination))
   :errback errback))

(cl-defmethod ecim-provider-cancel-run ((_p (eql github)) repo run-id callback &optional errback)
  "Cancel RUN-ID of REPO through /actions/runs/ID/cancel.
CALLBACK and ERRBACK receive the outcome."
  (ecim-github--request
   repo (format "/actions/runs/%s/cancel" run-id)
   :method "POST" :reader 'none :callback callback :errback errback))

(cl-defmethod ecim-provider-rerun-run ((_p (eql github)) repo run-id failed-only
                                       callback &optional errback)
  "Rerun RUN-ID of REPO, only its failed jobs when FAILED-ONLY.
CALLBACK and ERRBACK receive the outcome."
  (ecim-github--request
   repo (format "/actions/runs/%s/%s" run-id
                (if failed-only "rerun-failed-jobs" "rerun"))
   :method "POST" :reader 'none :callback callback :errback errback))

(cl-defmethod ecim-provider-rerun-job ((_p (eql github)) repo job-id callback &optional errback)
  "Rerun JOB-ID of REPO through /actions/jobs/ID/rerun.
CALLBACK and ERRBACK receive the outcome."
  (ecim-github--request
   repo (format "/actions/jobs/%s/rerun" job-id)
   :method "POST" :reader 'none :callback callback :errback errback))

;;;; Manual dispatch
;;
;; The Actions API does not report the inputs a workflow declares, so
;; the workflow file itself is read.  Emacs has no YAML parser and
;; ECIM avoids extra dependencies, so the small reader below walks
;; only the on.workflow_dispatch.inputs subtree by indentation.  When
;; it cannot make sense of the file the caller falls back to asking
;; for free-form values.

(defun ecim-github--yaml-lines (text)
  "Split TEXT into (INDENT . CONTENT) pairs, dropping blanks and comments."
  (let (lines)
    (dolist (raw (split-string text "\n"))
      (let ((line (replace-regexp-in-string "[ \t]+\\'" "" raw)))
        ;; Only strip trailing comments from lines without quoting, so
        ;; a value such as `default: "a # b"' survives intact.
        (when (and (not (string-match-p "[\"']" line))
                   (string-match "[ \t]+#.*\\'" line))
          (setq line (substring line 0 (match-beginning 0))))
        (unless (or (string-match-p "\\`[ \t]*\\'" line)
                    (string-match-p "\\`[ \t]*#" line)
                    (string-match-p "\\`---" line))
          (string-match "\\`\\( *\\)" line)
          (push (cons (length (match-string 1 line)) (string-trim line)) lines))))
    (nreverse lines)))

(defun ecim-github--yaml-deeper (lines indent)
  "Return the leading run of LINES indented more than INDENT."
  (let (acc)
    (catch 'done
      (dolist (entry lines)
        (if (> (car entry) indent)
            (push entry acc)
          (throw 'done nil))))
    (nreverse acc)))

(defun ecim-github--yaml-block (lines key)
  "Return the lines nested under KEY within LINES."
  (let ((rest lines) block)
    (while (and rest (null block))
      (let ((entry (car rest)))
        (when (string-match-p (concat "\\`" (regexp-quote key) ":") (cdr entry))
          (setq block (ecim-github--yaml-deeper (cdr rest) (car entry))))
        (setq rest (cdr rest))))
    block))

(defun ecim-github--yaml-unquote (value)
  "Strip surrounding quotes from VALUE."
  (let ((value (string-trim value)))
    (if (and (> (length value) 1)
             (memq (aref value 0) '(?\" ?'))
             (eq (aref value 0) (aref value (1- (length value)))))
        (substring value 1 -1)
      value)))

(defun ecim-github--yaml-scalar (lines key)
  "Return the scalar stored under KEY in LINES, or nil."
  (let ((rest lines) value)
    (while (and rest (null value))
      (let ((content (cdr (car rest))))
        (when (string-match (concat "\\`" (regexp-quote key) ":[ \t]*\\(.*\\)\\'") content)
          (let ((raw (ecim-github--yaml-unquote (match-string 1 content))))
            (setq value (unless (string-empty-p raw) raw)))))
      (setq rest (cdr rest)))
    value))

(defun ecim-github--yaml-sequence (lines key)
  "Return the list of items stored under KEY in LINES."
  (delq nil
        (mapcar (lambda (entry)
                  (when (string-match "\\`-[ \t]*\\(.+\\)\\'" (cdr entry))
                    (ecim-github--yaml-unquote (match-string 1 (cdr entry)))))
                (ecim-github--yaml-block lines key))))

(defun ecim-github--input (name lines)
  "Build an `ecim-input' called NAME from its attribute LINES."
  (let ((options (ecim-github--yaml-sequence lines "options"))
        (type (ecim-github--yaml-scalar lines "type")))
    (ecim-input-create
     :name name
     :description (ecim-github--yaml-scalar lines "description")
     :required (and (member (ecim-github--yaml-scalar lines "required") '("true" "yes")) t)
     :default (ecim-github--yaml-scalar lines "default")
     :type (ecim--symbol (or type (if options "choice" "string")))
     :options options)))

(defun ecim-github--dispatch-inputs (yaml)
  "Return the `workflow_dispatch' inputs declared in YAML."
  (let* ((lines (ecim-github--yaml-lines yaml))
         (dispatch (ecim-github--yaml-block lines "workflow_dispatch"))
         (block (and dispatch (ecim-github--yaml-block dispatch "inputs"))))
    (when block
      (let ((base (apply #'min (mapcar #'car block)))
            (rest block)
            inputs)
        (while rest
          (let ((entry (car rest)))
            (if (and (= (car entry) base)
                     (string-match "\\`\\([A-Za-z0-9_.-]+\\):" (cdr entry)))
                (let* ((name (match-string 1 (cdr entry)))
                       (attrs (ecim-github--yaml-deeper (cdr rest) base)))
                  (push (ecim-github--input name attrs) inputs)
                  (setq rest (nthcdr (1+ (length attrs)) rest)))
              (setq rest (cdr rest)))))
        (nreverse inputs)))))

(cl-defmethod ecim-provider-workflow-inputs ((_p (eql github)) repo workflow ref
                                             callback &optional _errback)
  "Read the manual inputs WORKFLOW of REPO declares at REF.
The API does not report them, so the workflow file is fetched and
parsed.  CALLBACK receives the inputs, or nil when the file cannot
be read, which lets the caller ask for values by hand."
  (ecim-github--request
   repo (format "/repos/%s/%s/contents/%s"
                (ecim-repo-owner repo) (ecim-repo-name repo)
                (ecim-workflow-path workflow))
   :params `(("ref" . ,ref))
   :callback (lambda (body)
               (let* ((encoded (alist-get 'content body))
                      (yaml (and encoded
                                 (ignore-errors
                                   (decode-coding-string
                                    (base64-decode-string
                                     (replace-regexp-in-string "[\n\r]" "" encoded))
                                    'utf-8)))))
                 (funcall callback
                          (and yaml (ignore-errors (ecim-github--dispatch-inputs yaml))))))
   ;; A missing or unreadable workflow file is not fatal: the caller
   ;; can still ask for inputs by hand.
   :errback (lambda (_err) (funcall callback nil))))

(defconst ecim-github--dispatch-poll-delays '(2 3 5 8)
  "Seconds to wait between attempts at locating a dispatched run.")

(defun ecim-github--find-dispatched-run (repo workflow ref after callback delays)
  "Look for the run of WORKFLOW in REPO on REF created after AFTER.
Retries on the schedule in DELAYS before giving up and calling
CALLBACK with nil."
  (if (null delays)
      (funcall callback nil)
    (run-at-time
     (car delays) nil
     (lambda ()
       (ecim-provider-list-runs
        'github repo
        (list :workflow-id (ecim-workflow-id workflow) :event "workflow_dispatch" :limit 10)
        (lambda (runs)
          (let ((match (seq-find
                        (lambda (run)
                          (and (or (null ref) (equal (ecim-run-branch run) ref))
                               (ecim-run-created-at run)
                               (time-less-p after (ecim-run-created-at run))))
                        runs)))
            (if match
                (funcall callback match)
              (ecim-github--find-dispatched-run repo workflow ref after callback
                                                (cdr delays)))))
        (lambda (_err)
          (ecim-github--find-dispatched-run repo workflow ref after callback
                                            (cdr delays))))))))

(cl-defmethod ecim-provider-trigger-workflow ((_p (eql github)) repo workflow ref inputs
                                              callback &optional errback)
  "Dispatch WORKFLOW of REPO on REF with INPUTS.
CALLBACK and ERRBACK receive the outcome."
  (let ((payload (list :ref ref))
        (dispatched (time-add nil -10)))
    (when inputs
      (let ((table (make-hash-table :test #'equal)))
        (dolist (cell inputs)
          (puthash (car cell) (cdr cell) table))
        (setq payload (list :ref ref :inputs table))))
    (ecim-github--request
     repo (format "/actions/workflows/%s/dispatches" (ecim-workflow-id workflow))
     :method "POST" :data payload :reader 'none
     :callback (lambda (_body)
                 ;; A dispatch returns 204 with no body, so the new run
                 ;; has to be discovered by polling for it.
                 (ecim-github--find-dispatched-run repo workflow ref dispatched
                                                   callback
                                                   ecim-github--dispatch-poll-delays))
     :errback errback)))

(provide 'ecim-github)
;;; ecim-github.el ends here
