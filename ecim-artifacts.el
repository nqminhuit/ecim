;;; ecim-artifacts.el --- Workflow artifacts for ECIM  -*- lexical-binding: t; -*-

;;; Commentary:

;; Lists the artifacts a run produced and downloads them.  Artifacts
;; arrive as zip archives, which are written verbatim; opening one
;; with `archive-mode' is offered afterwards.

;;; Code:

(require 'ecim-core)
(require 'ecim-provider)
(require 'ecim-ui)

(defcustom ecim-artifact-directory (locate-user-emacs-file "ecim/")
  "Directory into which artifacts are downloaded."
  :type 'directory
  :group 'ecim)

(defvar-local ecim--artifacts-run nil
  "Run whose artifacts this buffer lists.")

(defvar ecim-artifacts-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'ecim-artifacts-download)
    (define-key map (kbd "d") #'ecim-artifacts-download)
    map)
  "Keymap for `ecim-artifacts-mode'.")

(define-derived-mode ecim-artifacts-mode ecim-list-mode "ECIM-Artifacts"
  "Major mode listing the artifacts of a workflow run."
  (setq tabulated-list-format
        [("Artifact" 34 t) ("Size" 10 t) ("Created" 12 nil) ("Expires" 12 nil)])
  (setq ecim--column-caps [50 nil nil nil])
  (tabulated-list-init-header))

(defun ecim-artifacts--entry (artifact)
  "Return a `tabulated-list-entries' element for ARTIFACT."
  (list artifact
        (vector (propertize (ecim-artifact-name artifact)
                            'face (when (ecim-artifact-expired artifact) 'ecim-pending))
                (file-size-human-readable (or (ecim-artifact-size artifact) 0))
                (ecim--relative-time (ecim-artifact-created-at artifact))
                (if (ecim-artifact-expired artifact)
                    (propertize "expired" 'face 'ecim-pending)
                  (ecim--relative-time (ecim-artifact-expires-at artifact))))))

(defun ecim-artifacts-download ()
  "Download the artifact on the current line."
  (interactive)
  (let* ((artifact (ecim--entry))
         (repo ecim--repo)
         (buffer (current-buffer)))
    (when (ecim-artifact-expired artifact)
      (user-error "Artifact %s has expired" (ecim-artifact-name artifact)))
    (let ((destination (expand-file-name
                        (format "%s-%s.zip" (ecim-artifact-name artifact)
                                (ecim-artifact-id artifact))
                        (file-name-as-directory ecim-artifact-directory))))
      (when (or (not (file-exists-p destination))
                (yes-or-no-p (format "Overwrite %s? " (abbreviate-file-name destination))))
        (message "ECIM: downloading %s…" (ecim-artifact-name artifact))
        (ecim--set-loading buffer t)
        (ecim-provider-download-artifact
         (ecim-provider-for-repo repo) repo artifact destination
         (lambda (file)
           (ecim--set-loading buffer nil)
           (message "ECIM: saved %s" (abbreviate-file-name file))
           (ecim--later
            (lambda ()
              (when (y-or-n-p (format "Open %s? " (file-name-nondirectory file)))
                (find-file file)))))
         (ecim--errback buffer))))))

(defun ecim-artifacts--load (buffer repo run)
  "Fill BUFFER with the artifacts of RUN in REPO."
  (ecim--set-loading buffer t)
  (ecim-provider-list-artifacts
   (ecim-provider-for-repo repo) repo (ecim-run-id run)
   (lambda (artifacts)
     (ecim--fill buffer (mapcar #'ecim-artifacts--entry artifacts)
                 (format "#%s · %d artifact%s"
                         (ecim-run-number run) (length artifacts)
                         (if (= (length artifacts) 1) "" "s"))))
   (ecim--errback buffer)))

;;;###autoload
(defun ecim-show-artifacts (repo run)
  "List the artifacts produced by RUN in REPO."
  (let ((buffer (ecim--show-buffer
                 (ecim--buffer-name "artifacts" repo (format "#%s" (ecim-run-number run)))
                 'ecim-artifacts-mode repo)))
    (with-current-buffer buffer
      (setq ecim--artifacts-run run
            ecim--refresh-function (lambda () (ecim-artifacts--load buffer repo run))))
    (ecim--display buffer)
    (ecim-artifacts--load buffer repo run)
    buffer))

(provide 'ecim-artifacts)
;;; ecim-artifacts.el ends here
