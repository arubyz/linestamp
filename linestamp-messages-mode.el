;;; linestamp-message-mode.el --- Enable `linestamp-mode' for *Messages*

;; Copyright (C) 2016 <arubyz@gmail.com>

;; Author: <arubyz@gmail.com>
;; Keywords: tools, maint

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Implements a global minor mode which turns on `linestamp-mode' in the
;; *Messages* buffer, and set up necessary hooks to ensure that all lines have
;; timestamps even though `after-change-functions' is always not executed for
;; the *Messages* buffer.
;;
;; To reliably detect when changes occur in the *Messages* buffer, this module
;; takes ownership of the buffer's modified flag, and check/clears it in an idle
;; timer.  This should not cause conflicts since the *Messages* buffer is never
;; file-backed, and so its modified flag is otherwise unused.
;;

;;; Code:
(require 'z-hook)
(require 'linestamp-mode)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Customizations
;;

;;;###autoload
(defgroup linestamp-messages-mode ()
"Customization group for global minor mode `linestamp-messages-mode'")

;;;###autoload
(defcustom linestamp-messages-mode:timer-period 1
"The number of seconds the repeat idle timer waits before checking for changes
in the *Messages* buffer when `linestamp-messages-mode' is enabled."
  :type 'integer
  :group 'linestamp-messages-mode)

;;;###autoload
(defcustom linestamp-messages-mode:before-update-hook nil
"Hook called before timestamps are updated in the *Messages* buffer due to
changes being detect in the idle timer.  This hook is not run when changes
are detected through `after-change-hook', in which case the hook
`linestamp-mode:before-update-hook' is run.  The current buffer is the buffer
whose timestamps are to be updated."
  :type 'hook
  :group 'linestamp-messages-mode)

;;;###autoload
(defcustom linestamp-messages-mode:before-update-hook nil
"Hook called after timestamps are updated in the *Messages* buffer due to
changes being detect in the idle timer.  This hook is not run when changes
are detected through `after-change-hook', in which case the hook
`linestamp-mode:after-update-hook' is run.  The current buffer is the buffer
whose timestamps were updated."
  :type 'hook
  :group 'linestamp-messages-mode)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public interface
;;

;;;###autoload
(define-minor-mode linestamp-messages-mode
  ;; The default docstring is good enough
  nil
  
  ;; This mode doesn't need a mode-line indicator string
  :lighter nil

  ;; Customization group
  :group 'linestamp-messages-mode

  ;; The mode is global, since there is only one *Messages* buffer
  :global t
  
  ;; When turning the mode on ...
  (when (bound-and-true-p linestamp-messages-mode)
    (with-current-buffer (messages-buffer)
      ;; Ensure `linestamp-mode' is turned on in the *Messages* buffer
      (linestamp-mode +1)
      ;; Add all the local hooks this mode needs
      (linestamp-messages-mode:-setup-hooks)
      ;; Start the timer that will observe for buffer changes
      (linestamp-messages-mode:-start-timer)))

  ;; When turning the mode off ...
  (unless (bound-and-true-p linestamp-messages-mode)
    (with-current-buffer (messages-buffer)
      ;; Stop the timer.  Do this first to ensure it doesn't fire during some
      ;; other part of the minor mode tear-down process.
      (linestamp-messages-mode:-start-timer)
      ;; Turn off all hooks.  We must do this before turning off
      ;; `linestamp-mode', otherwise we'll respond (via a hook) to it being
      ;; turned off, and we'll have infinite recursion.
      (linestamp-messages-mode:-remove-hooks)
      ;; Ensure `linestamp-mode' is turned off in the *Messages* buffer
      (linestamp-mode -1))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internals
;;

(add-hook 'messages-buffer-mode-hook
          (defun linestamp-messages-mode:-message-buffer-mode-hook ()
"Function for `messages-buffer-mode-hook' which turns on `linestamp-mode' in
any *Messages* buffer if the `linestamp-messages-mode' global minor mode is
turned on.  A new *Messages* buffer may be created if the old *Messages* buffer
is killed."
            (when (bound-and-true-p linestamp-messages-mode)
              (linestamp-mode +1))))

(defun linestamp-messages-mode:-check-for-changes ()
"Determines (via the buffer modification flag) whether the *Messages* buffer has
changed without being observed by `after-change-hook'.  If so, any missing
timestamps at the end of the buffer are added, and the buffer modification flag
is cleared.

If a change is detected by this function, `linestamp-mode:before-update-hook'
is run before any missing timestamps are potentially added, and
`linestamp-mode:before-update-hook' is run after any timestamps are added and
the buffer modification flag has been cleared."
  (with-current-buffer (messages-buffer)
    (when (buffer-modified-p)
      ;; Run any before hooks
      (run-hooks 'linestamp-mode:before-update-hook)
      ;; There have been changes which weren't observed by `after-change-hook'.
      ;; Since the *Messages* buffer always updates at the end of the buffer, we
      ;; only need to look for missing timestamps there.  The timestamps we add
      ;; will be as precise as `linestamp-messages-mode:timer-period'.
      (linestamp-mode:add-missing-timetstamps-at-eob)
      ;; Clear the modified flag since we've handled the latest changes
      (set-buffer-modified-p nil)
      ;; Run any after hooks
      (run-hooks 'linestamp-mode:after-update-hook))))

(defvar linestamp-messages-mode:-timer nil
"A timer used to periodically check if the *Messages* buffer has been modified
without triggering `after-change-hook'")

(defun linestamp-messages-mode:-start-timer ()
"Starts the timer stored in `linestamp-messages-mode:-timer'"
  (unless linestamp-messages-mode:-timer
    (setq linestamp-messages-mode:-timer
          (run-at-time linestamp-messages-mode:timer-period ; TIME
                       linestamp-messages-mode:timer-period ; REPEAT
                       'linestamp-messages-mode:-check-for-changes))))

(defun linestamp-messages-mode:-stop-timer ()
"Stops the timer stored in `linestamp-messages-mode:-timer'"
  (when linestamp-messages-mode:-timer
    (cancel-timer linestamp-messages-mode:-timer)
    (setq linestamp-messages-mode:-timer nil)))

(defun linestamp-messages-mode:-before-update-hook ()
"Function for `linestamp-mode:before-update-hook' which ensure that, prior to
updating timestamps in response to `after-change-hook', any missing timestamps
at the end of the buffer are added."
  ;; Add any missing timestamps at EOB before the regular `linestamp-mode'
  ;; behavior forcibly updates all timestamps in the changed are.  This must be
  ;; done first since the area with missing timestamps is usually before the
  ;; changed area.
  (linestamp-mode:add-missing-timetstamps-at-eob))

(defun linestamp-messages-mode:-after-update-hook ()
"Function for `linestamp-mode:after-update-hook' which clears the modified flag
for the messages buffer, so that subsequent invocations of the idle timer don't
cause us to re-process the buffer unnecessarily."
  ;; Clear the modified flag since we've handled the latest changes
  (set-buffer-modified-p nil))

(defun linestamp-messages-mode:-linestamp-mode-hook ()
"Function for `linestamp-mode-hook' which turns off `linestamp-messages-mode'
if `linestamp-mode' is turned off in the *Messages* buffer.  This is done for
logical consistency, since `linestamp-messages-mode' does nothing if
`linestamp-mode' is not enabled."
  (linestamp-messages-mode -1))

(defun linestamp-messages-mode:-change-major-mode-hook ()
"Function for `change-major-mode-hook' which turns off `linestamp-mode' (and
hence `linestamp-messages-mode') if the major mode of the *Messages* is
changed.  This is necessary because `linestamp-messages-mode' relies on
buffer-local hooks which will be killed when the major mode is changed (see
`kill-all-local-variables')."
  ;; Note this must be done before changing the major mode, since it's a local
  ;; hook and will get killed when the major mode actually changes.  Hence we
  ;; can't do this in `after-change-major-mode-hook'.
  (linestamp-mode -1))

(defconst linestamp-messages-mode:-hook-list
  '((linestamp-mode:before-update-hook
     linestamp-messages-mode:-before-update-hook
     append 'local)
    (linestamp-mode:after-update-hook
     linestamp-messages-mode:-after-update-hook
     append 'local)
    (linestamp-mode-hook
     linestamp-messages-mode:-linestamp-mode-hook
     append 'local)
    (change-major-mode-hook
     linestamp-messages-mode:-change-major-mode-hook
     append 'local))
"A list of all hooks added and removed by `linestamp-messages-mode'.  The format
is consistent with `z:add-all-hooks'.")

(defun linestamp-messages-mode:-setup-hooks ()
"Adds all hooks needed to initialize `linestamp-messages-mode'"
  (z:add-all-hooks linestamp-messages-mode:-hook-list))

(defun linestamp-messages-mode:-remove-hooks ()
"Removes all hooks added by `linestamp-messages-mode:-setup-hooks'"
  (z:remove-all-hooks linestamp-messages-mode:-hook-list))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(provide 'linestamp-messages-mode)
;;; linestamp-messages-mode.el ends here
