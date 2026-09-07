;;; ecim-core.el --- Provider-independent core for ECIM  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ECIM contributors

;;; Commentary:

;; Data types, formatting helpers and error conditions shared by every
;; ECIM provider.  Nothing here knows about GitHub.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'parse-time)

(defgroup ecim nil
  "Manage CI/CD workflows from Emacs."
  :group 'tools
  :prefix "ecim-")

(define-error 'ecim-error "ECIM error")
(define-error 'ecim-auth-error "ECIM authentication error" 'ecim-error)
(define-error 'ecim-http-error "ECIM request failed" 'ecim-error)

;;;; Faces

(defface ecim-success '((t :inherit success))
  "Face for successful runs and jobs.")

(defface ecim-failure '((t :inherit error))
  "Face for failed runs and jobs.")

(defface ecim-running '((t :inherit warning))
  "Face for runs and jobs that are still in progress.")

(defface ecim-pending '((t :inherit shadow))
  "Face for queued, skipped or neutral runs and jobs.")

;;;; Data types
;;
;; Providers translate their own vocabulary into these structs, so the
;; UI never has to know how a particular service spells "failure".

(cl-defstruct (ecim-repo (:constructor ecim-repo-create) (:copier nil))
  root host owner name account)

(cl-defstruct (ecim-workflow (:constructor ecim-workflow-create) (:copier nil))
  id name path state url)

(cl-defstruct (ecim-run (:constructor ecim-run-create) (:copier nil))
  id number name workflow-id status conclusion branch event actor sha title
  created-at updated-at url)

(cl-defstruct (ecim-job (:constructor ecim-job-create) (:copier nil))
  id run-id name status conclusion started-at completed-at url)

(cl-defstruct (ecim-artifact (:constructor ecim-artifact-create) (:copier nil))
  id name size expired created-at expires-at)

(cl-defstruct (ecim-input (:constructor ecim-input-create) (:copier nil))
  name description required default type options)

(defun ecim-repo-slug (repo)
  "Return REPO as \"owner/name\"."
  (format "%s/%s" (ecim-repo-owner repo) (ecim-repo-name repo)))

(defun ecim-run-active-p (run)
  "Return non-nil if RUN has not finished yet."
  (not (eq (ecim-run-status run) 'completed)))

;;;; Status presentation

(defconst ecim--status-symbols
  '((success      . ("✓" ecim-success))
    (failure      . ("✗" ecim-failure))
    (timed-out    . ("⧖" ecim-failure))
    (startup-failure . ("✗" ecim-failure))
    (cancelled    . ("⊘" ecim-pending))
    (skipped      . ("»" ecim-pending))
    (neutral      . ("–" ecim-pending))
    (stale        . ("–" ecim-pending))
    (action-required . ("!" ecim-running))
    (in-progress  . ("⟳" ecim-running))
    (queued       . ("○" ecim-pending))
    (waiting      . ("○" ecim-pending))
    (pending      . ("○" ecim-pending))
    (requested    . ("○" ecim-pending)))
  "Mapping of normalized status/conclusion symbols to glyph and face.")

(defun ecim--status-symbol (status conclusion)
  "Return a propertized glyph describing STATUS and CONCLUSION.
A completed item is described by its CONCLUSION, anything else by
its STATUS."
  (let* ((key (if (eq status 'completed) (or conclusion 'neutral) status))
         (cell (or (cdr (assq key ecim--status-symbols)) '("?" ecim-pending))))
    (propertize (car cell) 'face (cadr cell) 'help-echo (symbol-name key))))

(defun ecim--status-string (status conclusion)
  "Return a readable label for STATUS and CONCLUSION."
  (let ((key (if (eq status 'completed) (or conclusion 'neutral) status)))
    (propertize (replace-regexp-in-string "-" " " (symbol-name key))
                'face (cadr (or (cdr (assq key ecim--status-symbols))
                                '("?" ecim-pending))))))

;;;; Time

(defun ecim--parse-time (string)
  "Parse an ISO 8601 STRING into an Emacs time value, or return nil."
  (when (and (stringp string) (not (string-empty-p string)))
    (ignore-errors (parse-iso8601-time-string string))))

(defun ecim--relative-time (time)
  "Return a compact description of how long ago TIME was."
  (if (null time)
      ""
    (let ((secs (max 0 (floor (float-time (time-subtract nil time))))))
      (cond ((< secs 60) (format "%ds ago" secs))
            ((< secs 3600) (format "%dm ago" (/ secs 60)))
            ((< secs 86400) (format "%dh ago" (/ secs 3600)))
            ((< secs 2592000) (format "%dd ago" (/ secs 86400)))
            (t (format-time-string "%Y-%m-%d" time))))))

(defun ecim--duration (start end)
  "Return the elapsed time between START and END as a short string.
END may be nil, in which case the current time is used."
  (if (null start)
      ""
    (let ((secs (max 0 (floor (float-time (time-subtract end start))))))
      (cond ((< secs 60) (format "%ds" secs))
            ((< secs 3600) (format "%dm%02ds" (/ secs 60) (% secs 60)))
            (t (format "%dh%02dm" (/ secs 3600) (/ (% secs 3600) 60)))))))

;;;; Misc helpers

(defun ecim--symbol (string)
  "Return STRING as a normalized lower-case symbol, or nil if empty.
Underscores become hyphens, so a provider spelling such as
\"in_progress\" reaches the rest of ECIM as `in-progress'."
  (when (and (stringp string) (not (string-empty-p string)))
    (intern (replace-regexp-in-string "_" "-" (downcase string)))))

(defun ecim--truncate (string width)
  "Truncate STRING to WIDTH columns, adding an ellipsis when cut."
  (let ((string (or string "")))
    (if (<= (string-width string) width)
        string
      (truncate-string-to-width string width nil nil t))))

(defun ecim--report-error (err)
  "Report ERR, an error object or string, to the user."
  (message "ECIM: %s"
           (cond ((stringp err) err)
                 ;; Our own errors already carry a complete sentence;
                 ;; `error-message-string' would only add quotes to it.
                 ((and (consp err) (symbolp (car err))
                       (memq 'ecim-error (get (car err) 'error-conditions))
                       (stringp (cadr err)) (null (cddr err)))
                  (cadr err))
                 ((and (consp err) (symbolp (car err)))
                  (error-message-string err))
                 (t (format "%S" err))))
  nil)

(defun ecim--later (function &rest args)
  "Call FUNCTION with ARGS from a timer.
Used to move prompts out of process filters, where entering a
recursive edit is unsafe."
  (apply #'run-at-time 0 nil function args))

(provide 'ecim-core)
;;; ecim-core.el ends here
