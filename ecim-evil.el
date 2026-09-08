;;; ecim-evil.el --- Optional Evil integration for ECIM  -*- lexical-binding: t; -*-

;;; Commentary:

;; ECIM has no dependency on Evil.  This file exists purely to react if
;; the user's own configuration has already loaded it: a modal-editing
;; package installs its own keymap for a mode (or an ancestor of it),
;; consulted before any major mode's own map, so a plain key binding in
;; ECIM's own keymaps is not enough to reach it once Evil is active.
;;
;; The whole file is inert until `evil' is loaded by someone else, so
;; requiring it costs nothing for anyone not running Evil.

;;; Code:

(require 'ecim-core)

(declare-function evil-local-set-key "evil")

;; Forward declarations, not requires: every one of these variables is
;; only ever read from inside a hook closure, which cannot run before
;; the view that defines it has already loaded (its mode has to exist
;; before a buffer can enter it and fire the hook).  `ecim-ui.el' in
;; particular cannot be required here: it is what requires this file,
;; and requiring it back would be a load cycle.
(defvar ecim-list-mode-map)
(defvar ecim-runs-mode-map)
(defvar ecim-jobs-mode-map)
(defvar ecim-workflows-mode-map)
(defvar ecim-artifacts-mode-map)
(defvar ecim-log-mode-map)

(defcustom ecim-evil-integration t
  "Whether ECIM reclaims its own keys from Evil, when Evil is present.
Has no effect unless Evil is already loaded."
  :type 'boolean
  :group 'ecim)

(defun ecim-evil--mirror-keymap (map)
  "Reapply each of MAP's own bindings as a local Evil key.
Uses Evil's normal state, since every ECIM buffer is read-only.
Only MAP's own bindings are mirrored, not its parent chain (which
would otherwise reach `global-map' and mirror everything from
`digit-argument' to `mouse-select-window')."
  (dolist (entry (ecim--keymap-own-bindings map))
    (evil-local-set-key 'normal (vector (car entry)) (cdr entry))))

(defun ecim-evil--mirror (map)
  "Mirror MAP for the current buffer, unless `ecim-evil-integration' is off."
  (when ecim-evil-integration
    (ecim-evil--mirror-keymap map)))

(with-eval-after-load 'evil
  ;; `ecim-list-mode-hook' fires for all four tabulated-list-derived
  ;; views (they all derive from `ecim-list-mode'), ahead of each
  ;; view's own hook -- `run-mode-hooks' always runs an ancestor
  ;; mode's hook before the more-derived mode's own, so this is
  ;; guaranteed to have already applied by the time the view-specific
  ;; hook below runs.
  (add-hook 'ecim-list-mode-hook (lambda () (ecim-evil--mirror ecim-list-mode-map)))
  (add-hook 'ecim-runs-mode-hook (lambda () (ecim-evil--mirror ecim-runs-mode-map)))
  (add-hook 'ecim-jobs-mode-hook (lambda () (ecim-evil--mirror ecim-jobs-mode-map)))
  (add-hook 'ecim-workflows-mode-hook (lambda () (ecim-evil--mirror ecim-workflows-mode-map)))
  (add-hook 'ecim-artifacts-mode-hook (lambda () (ecim-evil--mirror ecim-artifacts-mode-map)))
  ;; `ecim-log-mode' derives from `special-mode', not `ecim-list-mode',
  ;; so it needs its own hook rather than going through the one above.
  (add-hook 'ecim-log-mode-hook (lambda () (ecim-evil--mirror ecim-log-mode-map))))

(provide 'ecim-evil)
;;; ecim-evil.el ends here
