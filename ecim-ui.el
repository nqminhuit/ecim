;;; ecim-ui.el --- Shared buffer machinery for ECIM  -*- lexical-binding: t; -*-

;;; Commentary:

;; `ecim-list-mode' is the parent of every ECIM listing.  It owns what
;; the views have in common: which repository the buffer belongs to,
;; how to refresh it, and the optional auto-refresh timer that runs
;; only while something is still in progress.

;;; Code:

(require 'tabulated-list)
(require 'ecim-core)
(require 'ecim-provider)
(require 'ecim-repository)
;; `M-x ecim' autoloads a view (e.g. `ecim-runs.el'), not the package,
;; so `ecim.el' is never reached on a first invocation -- exactly the
;; bug once found in `ecim-provider-for-repo'.  This file is the seam
;; every view requires, so it is where Evil integration has to be
;; wired up for it to reliably apply.
(require 'ecim-evil)

(defcustom ecim-auto-refresh-interval nil
  "Seconds between automatic refreshes, or nil to refresh only on demand.
A buffer only reschedules itself while it still shows something
that has not finished, so idle buffers stop polling by themselves."
  :type '(choice (const :tag "Off" nil) integer)
  :group 'ecim)

(defvar-local ecim--repo nil
  "Repository this buffer shows.")

(defvar-local ecim--refresh-function nil
  "Function of no arguments that reloads this buffer.")

(defvar-local ecim--auto-refresh-timer nil
  "Timer used for automatic refreshes in this buffer.")

(defvar-local ecim--loading nil
  "Non-nil while a request for this buffer is in flight.")

(defvar-local ecim--status-line nil
  "Extra text shown in the header line.")

(defvar-local ecim--column-caps nil
  "Vector parallel to `tabulated-list-format' bounding column growth.
A number caps how wide that column may grow to fit its widest
cell; nil leaves it unbounded.  Set by a mode right after it sets
`tabulated-list-format', in modes whose columns should widen to
fit their data instead of always truncating to a fixed width.")

(defvar-local ecim--base-column-format nil
  "`tabulated-list-format' as the mode originally defined it.
Captured once, so each fill computes widths from the same
baseline rather than compounding onto an already-widened one.")

(defvar-local ecim--user-sized-columns nil
  "Names of columns the user has resized by hand with `{' or `}'.
`ecim--size-columns' leaves these at their current width instead
of recomputing them, so a manual resize survives the next refresh
rather than being silently undone by it.")

(defvar ecim-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'ecim-refresh)
    (define-key map (kbd "w") #'ecim-browse)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "{") #'ecim-narrow-column)
    (define-key map (kbd "}") #'ecim-widen-column)
    (define-key map (kbd "?") #'ecim-show-keybindings)
    map)
  "Keymap shared by all ECIM listings.")

(define-derived-mode ecim-list-mode tabulated-list-mode "ECIM"
  "Parent mode for ECIM listings."
  (setq tabulated-list-padding 1)
  (setq-local revert-buffer-function
              (lambda (&rest _) (ecim-refresh)))
  (add-hook 'kill-buffer-hook #'ecim--cancel-auto-refresh nil t))

(defun ecim--update-status ()
  "Show what this buffer is doing in the mode line.
The header line belongs to `tabulated-list-mode', which uses it
for the sortable column names."
  (setq mode-line-process
        (cond (ecim--loading (propertize " [loading…]" 'face 'ecim-pending))
              (ecim--status-line (format " [%s]" ecim--status-line))))
  (force-mode-line-update))

(defun ecim--set-loading (buffer flag)
  "Mark BUFFER as loading according to FLAG."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq ecim--loading flag)
      (ecim--update-status))))

(defun ecim-refresh ()
  "Reload the current ECIM buffer."
  (interactive)
  (unless ecim--refresh-function
    (user-error "Nothing to refresh here"))
  (funcall ecim--refresh-function))

(defun ecim--entry ()
  "Return the object on the current line, or signal a `user-error'."
  (or (tabulated-list-get-id)
      (user-error "No entry on this line")))

(defun ecim-browse ()
  "Open the entry on the current line in a web browser."
  (interactive)
  (let* ((entry (ecim--entry))
         (url (cond ((ecim-run-p entry) (ecim-run-url entry))
                    ((ecim-job-p entry) (ecim-job-url entry))
                    ((ecim-workflow-p entry) (ecim-workflow-url entry)))))
    (if url
        (browse-url url)
      (user-error "This entry has no web page"))))

(defun ecim--note-manual-column-resize (&rest _)
  "Remember that the column at point in an ECIM buffer was resized.
Advice on `tabulated-list-widen-current-column', so the resize is
recorded no matter which keymap called it.  A key binding in
`ecim-list-mode-map' is not enough on its own: a modal-editing
package such as Evil (through `evil-collection') installs its own
keymap for `tabulated-list-mode' at higher precedence than any
major mode's own map, and its `{'/`}' call the built-in directly,
bypassing `ecim-widen-column'/`ecim-narrow-column' entirely."
  (when (derived-mode-p 'ecim-list-mode)
    (let ((name (get-text-property (point) 'tabulated-list-column-name)))
      (when (and name (not (member name ecim--user-sized-columns)))
        (push name ecim--user-sized-columns)))))

(advice-add 'tabulated-list-widen-current-column :before
            #'ecim--note-manual-column-resize)

(defun ecim-widen-column (&optional n)
  "Widen the column at point by N characters.
A thin alias for `tabulated-list-widen-current-column', kept so
`ecim-list-mode-map' names a recognizably ECIM command; the actual
resize and the bookkeeping that makes it stick both live on the
built-in itself, via `ecim--note-manual-column-resize'."
  (interactive "p")
  (tabulated-list-widen-current-column n))

(defun ecim-narrow-column (&optional n)
  "Narrow the column at point by N characters.
See `ecim-widen-column'."
  (interactive "p")
  (tabulated-list-narrow-current-column n))

(defun ecim--keymap-entries (map)
  "Return an alist of (KEY-DESCRIPTION . COMMAND) for MAP's own bindings."
  (mapcar (lambda (entry) (cons (key-description (vector (car entry))) (cdr entry)))
          (ecim--keymap-own-bindings map)))

(defun ecim-show-keybindings ()
  "Show a short summary of this buffer's own ECIM keybindings.
`C-h m' documents the complete keymap, including everything
inherited from `tabulated-list-mode', `special-mode' and any
minor mode; this shows only what ECIM itself binds here."
  (interactive)
  (let* ((maps (if (derived-mode-p 'ecim-list-mode)
                   (list (current-local-map) ecim-list-mode-map)
                 (list (current-local-map))))
         ;; Captured before `with-help-window' switches `current-buffer'
         ;; to *ecim-keys*: its callback runs inside a `with-current-buffer'
         ;; on the help buffer, so `current-local-map'/`mode-name' read
         ;; from inside it would describe *ecim-keys*, not this buffer.
         (title mode-name)
         (entries (sort (delete-dups (apply #'append (mapcar #'ecim--keymap-entries maps)))
                        (lambda (a b) (string< (car a) (car b)))))
         (width (apply #'max 3 (mapcar (lambda (e) (length (car e))) entries))))
    ;; `display-buffer-overriding-action' takes priority over
    ;; `with-help-window''s own display action, so the cheat sheet gets a
    ;; small bottom popup instead of the usual half-height help window.
    (let ((display-buffer-overriding-action
           '((display-buffer-in-side-window)
             (side . bottom)
             (window-height . 0.25))))
      (with-help-window "*ecim-keys*"
        (princ (format "%s keybindings\n\n" title))
        (dolist (entry entries)
          (let ((key (car entry)))
            (princ (format "  %s%s  %s\n" key
                          (make-string (- width (length key)) ?\s)
                          (car (split-string (or (documentation (cdr entry)) "") "\n"))))))))))

;;;; Buffers

(defun ecim--buffer-name (kind repo &optional detail)
  "Return a buffer name of KIND for REPO, qualified by DETAIL."
  (if detail
      (format "*ecim %s: %s (%s)*" kind detail (ecim-repo-slug repo))
    (format "*ecim %s: %s*" kind (ecim-repo-slug repo))))

(defun ecim--show-buffer (name mode repo &optional refresh-function)
  "Return a buffer NAME in MODE for REPO, refreshed by REFRESH-FUNCTION.
Callers that need the buffer itself in the refresh closure set
`ecim--refresh-function' once this has returned."
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (unless (derived-mode-p mode)
        (funcall mode))
      (setq ecim--repo repo)
      (when refresh-function
        (setq ecim--refresh-function refresh-function))
      (ecim--update-status))
    buffer))

(defun ecim--size-columns (entries)
  "Widen the current buffer's columns to fit ENTRIES.
Each column in `ecim--base-column-format' grows to its widest
cell among ENTRIES, capped by the matching element of
`ecim--column-caps'.  A column with no cap set still cannot grow
past a cell that overflows it: `tabulated-list-print-col' truncates
with an ellipsis on its own, so a cap only guards against one huge
entry stretching the whole table for everyone else's sake.

A column the user has widened or narrowed by hand (see
`ecim-widen-column') is left at its current width instead: a
manual resize should survive the next refresh, not be recomputed
away by it."
  (let* ((base ecim--base-column-format)
         (caps ecim--column-caps)
         (previous tabulated-list-format)
         (format (copy-sequence base)))
    (dotimes (col (length format))
      (let* ((desc (aref format col))
             (name (car desc)))
        (if (member name ecim--user-sized-columns)
            (aset format col (aref previous col))
          (let ((cap (and caps (< col (length caps)) (aref caps col)))
                (width (max (nth 1 desc) (string-width name))))
            (dolist (entry entries)
              (let ((cell (aref (cadr entry) col)))
                (when (stringp cell)
                  (setq width (max width (string-width (substring-no-properties cell)))))))
            (when cap (setq width (min width cap)))
            (aset format col (cons name (cons width (cddr desc))))))))
    (setq tabulated-list-format format)
    (tabulated-list-init-header)))

(defun ecim--fill (buffer entries &optional status)
  "Display ENTRIES in BUFFER and note STATUS in its header line."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (unless ecim--base-column-format
        (setq ecim--base-column-format (copy-sequence tabulated-list-format)))
      (when ecim--column-caps
        (ecim--size-columns entries))
      (setq ecim--loading nil
            ecim--status-line status
            tabulated-list-entries entries)
      ;; Printing with `remember-pos' keeps point on the same entry
      ;; across a refresh instead of snapping back to the top.
      (tabulated-list-print t)
      (ecim--update-status)
      (ecim--reschedule-auto-refresh))))

(defun ecim--display (buffer)
  "Show BUFFER in the selected window."
  (pop-to-buffer-same-window buffer))

;;;; Asynchronous helpers

(defun ecim--callback (buffer function)
  "Return a callback running FUNCTION in BUFFER while it is alive."
  (lambda (&rest args)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (apply function args)))))

(defun ecim--errback (buffer)
  "Return an error handler that clears the loading state of BUFFER.
Auto-refresh is rearmed, so one failed request does not quietly
end polling on a run that is still going."
  (lambda (err)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq ecim--loading nil)
        (ecim--update-status)
        (ecim--reschedule-auto-refresh)))
    (ecim--report-error err)))

(defun ecim--provider (&optional repo)
  "Return the provider for REPO, defaulting to the buffer's repository."
  (ecim-provider-for-repo (or repo ecim--repo (ecim-repository-current))))

;;;; Auto refresh

(defun ecim--cancel-auto-refresh ()
  "Stop the auto-refresh timer of the current buffer."
  (when ecim--auto-refresh-timer
    (cancel-timer ecim--auto-refresh-timer)
    (setq ecim--auto-refresh-timer nil)))

(defvar-local ecim--auto-refresh-predicate nil
  "Function returning non-nil while this buffer should keep refreshing.")

(defun ecim--reschedule-auto-refresh ()
  "Schedule the next automatic refresh if the buffer still needs one."
  (ecim--cancel-auto-refresh)
  (when (and ecim-auto-refresh-interval
             ecim--refresh-function
             ecim--auto-refresh-predicate
             (funcall ecim--auto-refresh-predicate))
    (let ((buffer (current-buffer)))
      (setq ecim--auto-refresh-timer
            (run-at-time ecim-auto-refresh-interval nil
                         (lambda ()
                           (when (buffer-live-p buffer)
                             (with-current-buffer buffer
                               (setq ecim--auto-refresh-timer nil)
                               (when ecim--refresh-function
                                 (funcall ecim--refresh-function))))))))))

(provide 'ecim-ui)
;;; ecim-ui.el ends here
