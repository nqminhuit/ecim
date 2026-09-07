;;; ecim-provider.el --- CI provider interface for ECIM  -*- lexical-binding: t; -*-

;;; Commentary:

;; The seam between ECIM and a CI service.  It is deliberately thin:
;; a set of generic functions dispatching on a provider symbol.
;; Adding a provider means adding methods, not registering anything.
;;
;; Every operation is asynchronous.  CALLBACK is called with the
;; result -- always core structs, never raw API data -- and ERRBACK
;; with an error object if the request fails.

;;; Code:

(require 'cl-lib)
(require 'ecim-core)

(defcustom ecim-github-hosts '("github.com")
  "Hosts served by the GitHub provider.
Add GitHub Enterprise hostnames here."
  :type '(repeat string)
  :group 'ecim)

(defun ecim-provider-for-repo (repo)
  "Return the provider symbol handling REPO, loading its methods.
Selecting a provider is also the moment to make sure it exists: the
entry points autoload the views, which require this interface but
not any implementation, so without the `require' below the generics
would dispatch with no applicable method."
  (let ((host (ecim-repo-host repo)))
    (if (member host ecim-github-hosts)
        (progn (require 'ecim-github) 'github)
      (signal 'ecim-error
              (list (format "No ECIM provider knows how to talk to %s" host))))))

(cl-defgeneric ecim-provider-list-workflows (provider repo callback &optional errback)
  "Ask PROVIDER for the workflows of REPO.
CALLBACK receives a list of `ecim-workflow', ERRBACK an error.")

(cl-defgeneric ecim-provider-list-runs (provider repo query callback &optional errback)
  "Ask PROVIDER for the runs of REPO matching QUERY.
QUERY is a plist accepting :branch, :event, :workflow-id and
:limit.  CALLBACK receives a list of `ecim-run', ERRBACK an error.")

(cl-defgeneric ecim-provider-get-run (provider repo run-id callback &optional errback)
  "Ask PROVIDER for run RUN-ID of REPO.
CALLBACK receives an `ecim-run', ERRBACK an error.")

(cl-defgeneric ecim-provider-list-jobs (provider repo run-id callback &optional errback)
  "Ask PROVIDER for the jobs of RUN-ID in REPO.
CALLBACK receives a list of `ecim-job', ERRBACK an error.")

(cl-defgeneric ecim-provider-get-job-log (provider repo job-id callback &optional errback)
  "Ask PROVIDER for the log of JOB-ID in REPO.
CALLBACK receives the log as a string, ERRBACK an error.")

(cl-defgeneric ecim-provider-list-artifacts (provider repo run-id callback &optional errback)
  "Ask PROVIDER for the artifacts RUN-ID produced in REPO.
CALLBACK receives a list of `ecim-artifact', ERRBACK an error.")

(cl-defgeneric ecim-provider-download-artifact (provider repo artifact destination
                                                         callback &optional errback)
  "Ask PROVIDER to download ARTIFACT of REPO to DESTINATION.
CALLBACK receives the file name, ERRBACK an error.")

(cl-defgeneric ecim-provider-workflow-inputs (provider repo workflow ref callback
                                                       &optional errback)
  "Ask PROVIDER which manual inputs WORKFLOW of REPO declares at REF.
CALLBACK receives a possibly empty list of `ecim-input', ERRBACK
an error.")

(cl-defgeneric ecim-provider-trigger-workflow (provider repo workflow ref inputs
                                                        callback &optional errback)
  "Ask PROVIDER to run WORKFLOW of REPO on REF with INPUTS.
INPUTS is an alist of name and value.  CALLBACK receives the
resulting `ecim-run' if PROVIDER can identify it and nil
otherwise, ERRBACK an error.")

(cl-defgeneric ecim-provider-cancel-run (provider repo run-id callback &optional errback)
  "Ask PROVIDER to cancel RUN-ID of REPO.
CALLBACK is called when it has, ERRBACK on failure.")

(cl-defgeneric ecim-provider-rerun-run (provider repo run-id failed-only callback
                                                 &optional errback)
  "Ask PROVIDER to rerun RUN-ID of REPO.
Only failed jobs are rerun when FAILED-ONLY.  CALLBACK is called
when it has, ERRBACK on failure.")

(cl-defgeneric ecim-provider-rerun-job (provider repo job-id callback &optional errback)
  "Ask PROVIDER to rerun the single job JOB-ID of REPO.
CALLBACK is called when it has, ERRBACK on failure.")

(provide 'ecim-provider)
;;; ecim-provider.el ends here
