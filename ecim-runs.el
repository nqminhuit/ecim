;;; ecim-runs.el --- Run, job and workflow views for ECIM  -*- lexical-binding: t; -*-

;;; Commentary:

;; The dashboard and the views reachable from it: the runs of a
;; repository, the jobs of a run, the workflows of a repository, and
;; manual dispatch.

;;; Code:

(require 'ecim-core)
(require 'ecim-provider)
(require 'ecim-repository)
(require 'ecim-ui)
(require 'ecim-logs)
(require 'ecim-artifacts)

(defvar-local ecim--runs-query nil
  "Query plist used to populate the current runs buffer.")

(defvar-local ecim--jobs-run nil
  "Run whose jobs the current buffer lists.")

;;;; Runs

(defvar ecim-runs-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ecim-runs-visit)
    (define-key map (kbd "l") #'ecim-runs-logs)
    (define-key map (kbd "a") #'ecim-runs-artifacts)
    (define-key map (kbd "R") #'ecim-run-workflow)
    (define-key map (kbd "c") #'ecim-runs-cancel)
    (define-key map (kbd "G") #'ecim-runs-rerun)
    (define-key map (kbd "W") #'ecim-workflows)
    (define-key map (kbd "/") #'ecim-runs-filter-branch)
    map)
  "Keymap for `ecim-runs-mode'.")

(define-derived-mode ecim-runs-mode ecim-list-mode "ECIM-Runs"
  "Major mode listing workflow runs."
  (setq tabulated-list-format
        [("" 2 nil) ("Workflow" 22 t) ("Run" 7 nil) ("Branch" 20 t)
         ("Event" 12 t) ("Actor" 13 t) ("Age" 10 nil)])
  (setq ecim--auto-refresh-predicate #'ecim-runs--active-p)
  (tabulated-list-init-header))

(defun ecim-runs--active-p ()
  "Return non-nil if the current buffer lists an unfinished run."
  (seq-some (lambda (entry) (ecim-run-active-p (car entry)))
            tabulated-list-entries))

(defun ecim-runs--entry (run)
  "Return a `tabulated-list-entries' element for RUN."
  (list run
        (vector (ecim--status-symbol (ecim-run-status run) (ecim-run-conclusion run))
                (ecim--truncate (or (ecim-run-name run) "") 22)
                (format "#%s" (or (ecim-run-number run) "?"))
                (ecim--truncate (or (ecim-run-branch run) "") 20)
                (ecim--truncate (or (ecim-run-event run) "") 12)
                (ecim--truncate (or (ecim-run-actor run) "") 13)
                (if (ecim-run-active-p run)
                    (propertize (symbol-name (ecim-run-status run)) 'face 'ecim-running)
                  (ecim--relative-time (ecim-run-updated-at run))))))

(defun ecim-runs--load (buffer repo query)
  "Fill BUFFER with the runs of REPO matching QUERY."
  (ecim--set-loading buffer t)
  (ecim-provider-list-runs
   (ecim-provider-for-repo repo) repo query
   (lambda (runs)
     (ecim--fill buffer (mapcar #'ecim-runs--entry runs)
                 (concat (when (plist-get query :branch)
                           (format "branch %s · " (plist-get query :branch)))
                         (format "%d run%s" (length runs)
                                 (if (= (length runs) 1) "" "s")))))
   (ecim--errback buffer)))

;;;###autoload
(defun ecim-runs (&optional query)
  "Show the workflow runs of the current repository.
QUERY is an optional plist accepting :branch, :event, :status,
:workflow-id and :limit."
  (interactive)
  (let* ((repo (ecim-repository-current))
         (buffer (ecim--show-buffer (ecim--buffer-name "runs" repo) 'ecim-runs-mode repo)))
    (with-current-buffer buffer
      (setq ecim--runs-query query
            ecim--refresh-function
            (lambda () (ecim-runs--load buffer repo ecim--runs-query))))
    (ecim--display buffer)
    (ecim-runs--load buffer repo query)
    buffer))

;;;###autoload
(defalias 'ecim #'ecim-runs
  "Open the ECIM dashboard for the current repository.")

(defun ecim-runs-filter-branch (branch)
  "Restrict the current runs buffer to BRANCH, or to all branches if empty."
  (interactive
   (list (completing-read "Branch (empty for all): "
                          (ecim-repository-refs (or ecim--repo (ecim-repository-current)))
                          nil nil
                          (ecim-repository-current-branch
                           (ecim-repo-root (or ecim--repo (ecim-repository-current)))))))
  (setq ecim--runs-query
        (plist-put (copy-sequence ecim--runs-query)
                   :branch (unless (string-empty-p branch) branch)))
  (ecim-runs--load (current-buffer) ecim--repo ecim--runs-query))

(defun ecim-runs-visit ()
  "Show the jobs of the run on the current line."
  (interactive)
  (ecim-show-jobs ecim--repo (ecim--entry)))

(defun ecim-runs-artifacts ()
  "Show the artifacts of the run on the current line."
  (interactive)
  (ecim-show-artifacts ecim--repo (ecim--entry)))

(defun ecim-runs-logs ()
  "Show the log of a job belonging to the run on the current line."
  (interactive)
  (let ((repo ecim--repo)
        (run (ecim--entry)))
    (ecim-provider-list-jobs
     (ecim-provider-for-repo repo) repo (ecim-run-id run)
     (lambda (jobs)
       (cond
        ((null jobs) (message "ECIM: run #%s has no jobs yet" (ecim-run-number run)))
        ((null (cdr jobs)) (ecim-show-job-log repo (car jobs)))
        (t (ecim--later #'ecim-runs--pick-job repo jobs)))))))

(defun ecim-runs--pick-job (repo jobs)
  "Ask which of JOBS in REPO to show the log of."
  (let* ((names (mapcar #'ecim-job-name jobs))
         (choice (completing-read "Job: " names nil t))
         ;; `completing-read' returns the empty string on a bare RET even
         ;; with REQUIRE-MATCH, so a match is not guaranteed.
         (job (seq-find (lambda (job) (equal (ecim-job-name job) choice)) jobs)))
    (unless job (user-error "No job selected"))
    (ecim-show-job-log repo job)))

(defun ecim-runs-cancel ()
  "Cancel the run on the current line."
  (interactive)
  (let ((run (ecim--entry))
        (repo ecim--repo)
        (buffer (current-buffer)))
    (unless (ecim-run-active-p run)
      (user-error "Run #%s has already finished" (ecim-run-number run)))
    (when (yes-or-no-p (format "Cancel run #%s (%s)? "
                               (ecim-run-number run) (ecim-run-name run)))
      (ecim-provider-cancel-run
       (ecim-provider-for-repo repo) repo (ecim-run-id run)
       (lambda (&rest _)
         (message "ECIM: cancelling run #%s" (ecim-run-number run))
         (ecim--refresh-soon buffer))
       (ecim--errback buffer)))))

(defun ecim-runs-rerun (&optional failed-only)
  "Rerun the run on the current line.
With a prefix argument FAILED-ONLY, rerun only its failed jobs."
  (interactive "P")
  (let ((run (ecim--entry))
        (repo ecim--repo)
        (buffer (current-buffer)))
    (when (yes-or-no-p (format "Rerun %srun #%s? "
                               (if failed-only "failed jobs of " "")
                               (ecim-run-number run)))
      (ecim-provider-rerun-run
       (ecim-provider-for-repo repo) repo (ecim-run-id run) (and failed-only t)
       (lambda (&rest _)
         (message "ECIM: rerunning run #%s" (ecim-run-number run))
         (ecim--refresh-soon buffer))
       (ecim--errback buffer)))))

(defun ecim--refresh-soon (buffer &optional delay)
  "Refresh BUFFER after DELAY seconds, giving the provider time to react."
  (run-at-time (or delay 2) nil
               (lambda ()
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (when ecim--refresh-function
                       (funcall ecim--refresh-function)))))))

;;;; Jobs

(defvar ecim-jobs-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ecim-jobs-logs)
    (define-key map (kbd "l") #'ecim-jobs-logs)
    (define-key map (kbd "a") #'ecim-jobs-artifacts)
    (define-key map (kbd "G") #'ecim-jobs-rerun)
    map)
  "Keymap for `ecim-jobs-mode'.")

(define-derived-mode ecim-jobs-mode ecim-list-mode "ECIM-Jobs"
  "Major mode listing the jobs of a workflow run."
  (setq tabulated-list-format
        [("" 2 nil) ("Job" 38 t) ("Status" 14 t) ("Duration" 10 nil) ("Started" 12 nil)])
  (setq ecim--auto-refresh-predicate #'ecim-jobs--active-p)
  (tabulated-list-init-header))

(defun ecim-jobs--active-p ()
  "Return non-nil if the current buffer lists an unfinished job."
  (seq-some (lambda (entry) (not (eq (ecim-job-status (car entry)) 'completed)))
            tabulated-list-entries))

(defun ecim-jobs--entry (job)
  "Return a `tabulated-list-entries' element for JOB."
  (list job
        (vector (ecim--status-symbol (ecim-job-status job) (ecim-job-conclusion job))
                (ecim--truncate (or (ecim-job-name job) "") 38)
                (ecim--status-string (ecim-job-status job) (ecim-job-conclusion job))
                (ecim--duration (ecim-job-started-at job) (ecim-job-completed-at job))
                (ecim--relative-time (ecim-job-started-at job)))))

;;;###autoload
(defun ecim-jobs--load (buffer repo run)
  "Fill BUFFER with the jobs of RUN in REPO."
  (ecim--set-loading buffer t)
  (ecim-provider-list-jobs
   (ecim-provider-for-repo repo) repo (ecim-run-id run)
   (lambda (jobs)
     (ecim--fill buffer (mapcar #'ecim-jobs--entry jobs)
                 (format "#%s · %s" (ecim-run-number run)
                         (substring-no-properties
                          (ecim--status-string (ecim-run-status run)
                                               (ecim-run-conclusion run))))))
   (ecim--errback buffer)))

;;;###autoload
(defun ecim-show-jobs (repo run)
  "List the jobs of RUN in REPO."
  (let ((buffer (ecim--show-buffer
                 (ecim--buffer-name "jobs" repo (format "#%s" (ecim-run-number run)))
                 'ecim-jobs-mode repo)))
    (with-current-buffer buffer
      (setq ecim--jobs-run run
            ecim--refresh-function (lambda () (ecim-jobs--load buffer repo run))))
    (ecim--display buffer)
    (ecim-jobs--load buffer repo run)
    buffer))

(defun ecim-jobs-logs ()
  "Show the log of the job on the current line."
  (interactive)
  (ecim-show-job-log ecim--repo (ecim--entry)))

(defun ecim-jobs-artifacts ()
  "Show the artifacts of the run these jobs belong to."
  (interactive)
  (ecim-show-artifacts ecim--repo ecim--jobs-run))

(defun ecim-jobs-rerun ()
  "Rerun the job on the current line."
  (interactive)
  (let ((job (ecim--entry))
        (repo ecim--repo)
        (buffer (current-buffer)))
    (when (yes-or-no-p (format "Rerun job %s? " (ecim-job-name job)))
      (ecim-provider-rerun-job
       (ecim-provider-for-repo repo) repo (ecim-job-id job)
       (lambda (&rest _)
         (message "ECIM: rerunning %s" (ecim-job-name job))
         (ecim--refresh-soon buffer))
       (ecim--errback buffer)))))

;;;; Workflows

(defvar ecim-workflows-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ecim-workflows-runs)
    (define-key map (kbd "R") #'ecim-workflows-dispatch)
    map)
  "Keymap for `ecim-workflows-mode'.")

(define-derived-mode ecim-workflows-mode ecim-list-mode "ECIM-Workflows"
  "Major mode listing the workflows of a repository."
  (setq tabulated-list-format
        [("Workflow" 32 t) ("State" 12 t) ("File" 40 t)])
  (tabulated-list-init-header))

(defun ecim-workflows--load (buffer repo)
  "Fill BUFFER with the workflows of REPO."
  (ecim--set-loading buffer t)
  (ecim-provider-list-workflows
   (ecim-provider-for-repo repo) repo
   (lambda (workflows)
     (ecim--fill buffer (mapcar #'ecim-workflows--entry workflows)
                 (format "%d workflow%s" (length workflows)
                         (if (= (length workflows) 1) "" "s"))))
   (ecim--errback buffer)))

(defun ecim-workflows--entry (workflow)
  "Return a `tabulated-list-entries' element for WORKFLOW."
  (list workflow
        (vector (ecim--truncate (ecim-workflow-name workflow) 32)
                (propertize (symbol-name (or (ecim-workflow-state workflow) 'unknown))
                            'face (if (eq (ecim-workflow-state workflow) 'active)
                                      'ecim-success
                                    'ecim-pending))
                (ecim--truncate (or (ecim-workflow-path workflow) "") 40))))

;;;###autoload
(defun ecim-workflows ()
  "List the workflows of the current repository."
  (interactive)
  (let* ((repo (or ecim--repo (ecim-repository-current)))
         (buffer (ecim--show-buffer (ecim--buffer-name "workflows" repo)
                                    'ecim-workflows-mode repo)))
    (with-current-buffer buffer
      (setq ecim--refresh-function (lambda () (ecim-workflows--load buffer repo))))
    (ecim--display buffer)
    (ecim-workflows--load buffer repo)
    buffer))

(defun ecim-workflows-runs ()
  "Show the runs of the workflow on the current line."
  (interactive)
  (let ((workflow (ecim--entry)))
    (ecim-runs (list :workflow-id (ecim-workflow-id workflow)))))

(defun ecim-workflows-dispatch (&optional free-form)
  "Trigger the workflow on the current line.
FREE-FORM is passed to `ecim-run-workflow'."
  (interactive "P")
  (ecim-run-workflow free-form (ecim--entry)))

;;;; Manual dispatch

(defun ecim-runs--read-input (input)
  "Prompt for INPUT and return its value, or nil when left empty."
  (let* ((name (ecim-input-name input))
         (default (ecim-input-default input))
         (description (ecim-input-description input))
         (prompt (format "%s%s%s: "
                         name
                         (if description (format " (%s)" description) "")
                         (if (ecim-input-required input) " [required]" "")))
         ;; Asking again has to ask the same question: a choice input
         ;; retried as free text would send a value the workflow does
         ;; not accept, and the dispatch would fail with a 422.
         (read (lambda (prompt)
                 (pcase (ecim-input-type input)
                   ('choice (completing-read prompt (ecim-input-options input)
                                             nil t nil nil default))
                   ('boolean (completing-read prompt '("true" "false")
                                              nil t nil nil (or default "false")))
                   (_ (read-string prompt default)))))
         (value (funcall read prompt)))
    (while (and (ecim-input-required input) (string-empty-p (string-trim value)))
      (setq value (funcall read (format "%s is required: " name))))
    (unless (string-empty-p (string-trim value)) value)))

(defun ecim-runs--read-inputs (inputs)
  "Prompt for each of INPUTS and return an alist of names and values."
  (delq nil
        (mapcar (lambda (input)
                  (let ((value (ecim-runs--read-input input)))
                    (when value (cons (ecim-input-name input) value))))
                inputs)))

(defun ecim-runs--read-free-form ()
  "Read NAME=VALUE pairs until an empty answer is given."
  (let (inputs (more t))
    (while more
      (let ((pair (read-string "Input (name=value, empty to finish): ")))
        (cond
         ((string-empty-p (string-trim pair)) (setq more nil))
         ((string-match "\\`\\([^=]+\\)=\\(.*\\)\\'" pair)
          (push (cons (string-trim (match-string 1 pair)) (match-string 2 pair)) inputs))
         (t (message "ECIM: expected name=value")))))
    (nreverse inputs)))

(defun ecim-runs--dispatch (repo workflow ref inputs)
  "Trigger WORKFLOW of REPO on REF with INPUTS."
  (message "ECIM: triggering %s on %s…" (ecim-workflow-name workflow) ref)
  (ecim-provider-trigger-workflow
   (ecim-provider-for-repo repo) repo workflow ref inputs
   (lambda (run)
     (if run
         (progn
           (message "ECIM: started run #%s" (ecim-run-number run))
           (ecim-show-jobs repo run))
       (message "ECIM: %s triggered on %s" (ecim-workflow-name workflow) ref)))
   #'ecim--report-error))

(defun ecim-runs--dispatch-flow (repo workflow free-form)
  "Ask for a ref and inputs, then trigger WORKFLOW of REPO.
With FREE-FORM, ask for NAME=VALUE pairs regardless of what the
workflow declares."
  (let ((ref (completing-read
              (format "Run %s on ref: " (ecim-workflow-name workflow))
              (ecim-repository-refs repo) nil nil
              (ecim-repository-current-branch (ecim-repo-root repo)))))
    (when (string-empty-p (string-trim ref))
      (user-error "A ref is required"))
    (ecim-provider-workflow-inputs
     (ecim-provider-for-repo repo) repo workflow ref
     (lambda (inputs)
       (ecim--later
        (lambda ()
          (let ((values (cond (inputs (ecim-runs--read-inputs inputs))
                              (free-form (ecim-runs--read-free-form)))))
            (ecim-runs--dispatch repo workflow ref values)))))
     #'ecim--report-error)))

;;;###autoload
(defun ecim-run-workflow (&optional free-form workflow)
  "Trigger a workflow manually.
WORKFLOW is asked for when not supplied.  With a prefix argument
FREE-FORM, prompt for NAME=VALUE inputs even when none could be
detected in the workflow file."
  (interactive "P")
  (let ((repo (or ecim--repo (ecim-repository-current))))
    (if workflow
        (ecim-runs--dispatch-flow repo workflow free-form)
      (ecim-provider-list-workflows
       (ecim-provider-for-repo repo) repo
       (lambda (workflows)
         (ecim--later
          (lambda ()
            (let* ((active (or (seq-filter (lambda (w)
                                             (eq (ecim-workflow-state w) 'active))
                                           workflows)
                               workflows))
                   (names (mapcar #'ecim-workflow-name active)))
              (unless active
                (user-error "%s has no workflows" (ecim-repo-slug repo)))
              (let* ((choice (completing-read "Workflow: " names nil t))
                     (workflow (seq-find (lambda (w) (equal (ecim-workflow-name w) choice))
                                         active)))
                (unless workflow (user-error "No workflow selected"))
                (ecim-runs--dispatch-flow repo workflow free-form))))))
       #'ecim--report-error))))

(provide 'ecim-runs)
;;; ecim-runs.el ends here
