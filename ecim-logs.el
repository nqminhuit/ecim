;;; ecim-logs.el --- Job logs for ECIM  -*- lexical-binding: t; -*-

;;; Commentary:

;; Shows the log of a single job in a read-only buffer, with ANSI
;; colours applied and the workflow command markers (##[group],
;; ##[error] and friends) turned into something navigable.

;;; Code:

(require 'ansi-color)
(require 'ecim-core)
(require 'ecim-provider)
(require 'ecim-ui)

(defcustom ecim-logs-strip-timestamps t
  "Whether to remove the leading ISO timestamp from each log line."
  :type 'boolean
  :group 'ecim)

(defvar-local ecim--log-job nil
  "Job whose log this buffer shows.")

(defconst ecim-logs--timestamp-regexp
  "^[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T[0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}\\.[0-9]+Z "
  "Timestamp prefix GitHub puts in front of every log line.")

(defvar ecim-log-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "g") #'ecim-refresh)
    (define-key map (kbd "n") #'ecim-logs-next-step)
    (define-key map (kbd "p") #'ecim-logs-previous-step)
    (define-key map (kbd "w") #'ecim-logs-browse)
    (define-key map (kbd "?") #'ecim-show-keybindings)
    map)
  "Keymap for `ecim-log-mode'.")

(define-derived-mode ecim-log-mode special-mode "ECIM-Log"
  "Major mode for reading a CI job log."
  (setq-local revert-buffer-function (lambda (&rest _) (ecim-refresh)))
  (setq-local truncate-lines nil))

(defun ecim-logs--decorate ()
  "Clean up and fontify the log in the current buffer."
  (let ((inhibit-read-only t))
    (ansi-color-apply-on-region (point-min) (point-max))
    (when ecim-logs-strip-timestamps
      (goto-char (point-min))
      (while (re-search-forward ecim-logs--timestamp-regexp nil t)
        (replace-match "")))
    ;; Workflow commands are noise as text but useful as structure.
    (goto-char (point-min))
    (while (re-search-forward "^##\\[\\([a-z]+\\)\\]\\(.*\\)$" nil t)
      (let ((kind (match-string 1))
            (start (match-beginning 0)))
        (replace-match
         (pcase kind
           ("group" (propertize (concat "▸ " (match-string 2)) 'face 'bold))
           ("endgroup" "")
           ("error" (propertize (concat "error: " (match-string 2)) 'face 'ecim-failure))
           ("warning" (propertize (concat "warning: " (match-string 2)) 'face 'ecim-running))
           (_ (match-string 2)))
         t t)
        (when (member kind '("group" "error"))
          (put-text-property start (line-end-position) 'ecim-step kind))))
    (goto-char (point-min))))

(defun ecim-logs--goto-step (direction)
  "Move to the next log step in DIRECTION, 1 forwards or -1 backwards."
  (let ((search (if (> direction 0)
                    #'next-single-property-change
                  #'previous-single-property-change))
        (position (point))
        found)
    (while (and (not found)
                (setq position (funcall search position 'ecim-step)))
      (when (get-text-property position 'ecim-step)
        (setq found position)))
    (if found
        (goto-char found)
      (message "No further step"))))

(defun ecim-logs-next-step ()
  "Move to the next step header or error in the log."
  (interactive)
  (ecim-logs--goto-step 1))

(defun ecim-logs-previous-step ()
  "Move to the previous step header or error in the log."
  (interactive)
  (ecim-logs--goto-step -1))

(defun ecim-logs-browse ()
  "Open this job on the provider's web interface."
  (interactive)
  (if (and ecim--log-job (ecim-job-url ecim--log-job))
      (browse-url (ecim-job-url ecim--log-job))
    (user-error "This job has no web page")))

(defun ecim-logs--load (buffer repo job)
  "Fetch the log of JOB in REPO into BUFFER."
  (ecim--set-loading buffer t)
  (ecim-provider-get-job-log
   (ecim-provider-for-repo repo) repo (ecim-job-id job)
   (lambda (text) (ecim-logs--fill buffer text))
   (ecim--errback buffer)))

(defun ecim-logs--fill (buffer text)
  "Insert TEXT as the log contents of BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (or text ""))
        (ecim-logs--decorate))
      (setq ecim--loading nil)
      (ecim--update-status))))

;;;###autoload
(defun ecim-show-job-log (repo job)
  "Display the log of JOB in REPO."
  (let* ((name (ecim--buffer-name "log" repo (ecim-job-name job)))
         (buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'ecim-log-mode) (ecim-log-mode))
      (setq ecim--repo repo
            ecim--log-job job
            ecim--loading t
            ecim--status-line (substring-no-properties
                               (ecim--status-string (ecim-job-status job)
                                                    (ecim-job-conclusion job)))
            ecim--refresh-function (lambda () (ecim-logs--load buffer repo job)))
      (ecim--update-status)
      (let ((inhibit-read-only t))
        (unless (> (buffer-size) 0)
          (insert "Fetching log…\n"))))
    (ecim--display buffer)
    (ecim-logs--load buffer repo job)
    buffer))

(provide 'ecim-logs)
;;; ecim-logs.el ends here
