;;; linestamp-mode.el --- Show a modification timestamp for each line

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
;; Implements a minor mode which displays a per-line timestamp (or "linestamp")
;; indicating the time that line last changed.  This is useful for the
;; *Messages* buffer, chat sessions, log buffers, etc.  Timestamps can be
;; displayed in the left fringe, right fringe, or at the beginning of the line.
;;
;; If displaying timestamps in a fringe, this mode probably won't play well with
;; other modes that attempt to display information in the same fringe.
;;
;; Compatibility notes:
;;
;;  * Fully compatible with `shell' buffers.
;;
;;  * Fully compatible with `ielm' buffers.
;;
;;  * Fully compatible with buffers tailing logs via `auto-revert-tail-mode'
;;
;;  * Full compatibility with the *Messages* buffer is achieved by using the
;;    derived global minor mode `linestamp-message-mode'.
;;
;;  * Semi-compatible with `eshell' buffers.  Lines with user input are given
;;    timestamps, but lines with output are not.  It is a known issue that
;;    Eshell binds `after-change-functions' to nil in some places.  See:
;;
;;      ** https://lists.gnu.org/archive/html/emacs-devel/2010-07/msg01043.html
;;
;;  * Not compatible with `term' and `ansi-term' buffers.  Although it appears
;;    to work in common case, it also renders incorrectly in many other cases.
;;    Linestamps are not particularly useful in term buffers anyway, since any
;;    act of scrolling will update all linestamps at once.
;;

;;; Code:
(require 'cl)
(require 'dash)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Customizations
;;

;;;###autoload
(defgroup linestamp-mode ()
"Customization group for minor mode `linestamp-mode'")

;;;###autoload
(defcustom linestamp-mode:timestamp-string-format
  "%T.%3N"
"The format string used by `linestamp-mode:timestamp-string' (the default value
of `linestamp-mode:timestamp-string-function') to generate timestamp strings
using the function `format-time-string'.  This variable may be made buffer
local."
  :type 'string
  :group 'linestamp-mode)

;;;###autoload
(defcustom linestamp-mode:timestamp-string-function
  (defun linestamp-mode:timestamp-string ()
"Generates a timestamp for `linestamp-mode' using `format-time-string' and the
format value specified by `linestamp-mode:timestamp-string-format'.  The entire
string is displayed in the face `linestamp-mode:timestamp-face'.  This function
is the default value of `linestamp-mode:timestamp-string-function'."
    ;; Note: `linestamp-mode:timestamp-string-format' and
    ;; `linestamp-mode:timestamp-margin' may be buffer local
    (let ((timestamp (format-time-string linestamp-mode:timestamp-string-format
                                         (current-time))))
      ;; Return a string with a 'face property
      (propertize (if linestamp-mode:timestamp-margin
                      ;; Use the raw timestamp string if displaying in a fringe
                      timestamp
                    ;; Add some formatting if prepending to the line
                    (format "%s| " timestamp))
                  ;; Apply the timestamp face to the entire string
                  'face 'linestamp-mode:timestamp-face)))
"The function to call to generate timestamp strings shown with each line when
`linestamp-mode' is enabled.  When this function is called, the current buffer
is the buffer in which the timestamp will be displayed.  This variable may be
made buffer local."
  :type 'function-item
  :group 'linestamp-mode)

;;;###autoload
(defcustom linestamp-mode:placeholder-string-function
  (defun linestamp-mode:placeholder-string ()
"Generates a line prefix for `linestamp-mode' which is used as a placeholder
when the actual timestamp is not known.  The entire string is displayed in the
face `linestamp-mode:placeholder-face'.  This function  is the default value of
`linestamp-mode:placeholder-string-function'."
    ;; Return a string with a 'face property
    (propertize (if linestamp-mode:timestamp-margin
                    "------------"
                  "------------| ")
                ;; Apply the timestamp face to the entire string
                'face 'linestamp-mode:placeholder-face))
"The function to call to generate placeholder strings shown with each line when
`linestamp-mode' is enabled and the actual timestamp for the line is not known.
When this function is called, the current buffer  is the buffer in which the
placeholder will be displayed.  This variable may be made buffer local."
  :type 'function-item
  :group 'linestamp-mode)

;;;###autoload
(defcustom linestamp-mode:timestamp-margin
  'nil
"The margin value to use when configuring display properties for a timestamp
overlay.  Valid values are 'left-fringe, 'right-fringe, or nil (which will
prepend the timestamp to the beginning of the line).  This variable may be
made buffer local."
  :type '(choice (const :tag "Left margin" left-margin)
                 (const :tag "Right margin" right-margin)
                 (const :tag "Inline" nil))
  :group 'linestamp-mode)

;;;###autoload
(defface linestamp-mode:timestamp-face
  '((default :inherit success))
"Face used to render timestamps when `linestamp-mode' is enabled"
  :group 'linestamp-mode)

;;;###autoload
(defface linestamp-mode:placeholder-face
  '((default :inherit success))
"Face used to render placeholder prefixes when `linestamp-mode' is enabled"
  :group 'linestamp-mode)

;;;###autoload
(defcustom linestamp-mode:before-update-hook nil
"Hook called before timestamps are updated in a buffer.  The current buffer is
the buffer whose timestamps are to be updated."
  :type 'hook
  :group 'linestamp-mode)

;;;###autoload
(defcustom linestamp-mode:after-update-hook nil
"Hook called after timestamps are updated in a buffer.  The current buffer is
the buffer whose timestamps were updated."
  :type 'hook
  :group 'linestamp-mode)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public interface
;;

;;;###autoload
(define-minor-mode linestamp-mode
  ;; The default docstring is good enough
  nil
  
  ;; The mode-line indicator string
  :lighter " LStamp"

  ;; Customization group
  :group 'linestamp-mode
  
  ;; When turning the mode on ...
  (when (bound-and-true-p linestamp-mode)
    ;; Append our hook to the buffer's local change functions
    (add-hook 'after-change-functions
              'linestamp-mode:-after-change-function
              'append 'local)
    ;; Add placeholder timestamps to all lines in the buffer
    (linestamp-mode:add-missing-timetstamps (point-min) (point-max) t))

  ;; When turning the mode off ...
  (unless (bound-and-true-p linestamp-mode)
    ;; Remove our hook from the buffer's local change functions
    (remove-hook 'after-change-functions
                 'linestamp-mode:-after-change-function
                 'local)
    ;; Remove all overlays from the buffer
    (linestamp-mode:-remove-all-overlays)))

;;;###autoload
(defun linestamp-mode:add-missing-timetstamps (&optional beginning end placeholder?)
"Adds timestamp overlays to any line which does not already have a timestamp in
the area specified by BEGINNING and END in the current buffer.  If BEGINNING
is not specified it defaults to the beginning of the buffer.  If END is not
specified it defaults to the end of the buffer.  If PLACEHOLDER? is non-nil,
then an appropriately-wide placeholder strings is used as the line prefix,
instead of the current timestamp.  The buffer is temporarily widened during
this operation.

Normally timestamps are added automatically in response to buffer changes when
`linestamp-mode' is enabled.  However there may be cases where timestamps need
to be added manually, such as when buffer changes are made while
`inhibit-modification-hooks' is set to t.

Note that if `linestamp-mode' is not enabled in the current buffer, this
function does nothing."
  ;; Do nothing unless `linestamp-mode' is turned on
  (when (bound-and-true-p linestamp-mode)
    ;; Operate on this buffer in a temporary, unrestricted context
    (save-restriction
      (widen)
      (save-excursion
        ;; Add a timestamp to any line in the given region which doesn't already
        ;; have one
        (let ((beginning (or beginning (point-min)))
              (end (or end (point-max))))
          (loop initially (goto-char beginning)
                while (<= (point) end)
                until (eobp)
                unless (linestamp-mode:-get-overlays-on-line)
                  do (linestamp-mode:-add-overlay-to-line placeholder?)
                do (forward-line)))))))

;;;###autoload
(defun linestamp-mode:add-missing-timetstamps-at-eob (&optional placeholder?)
"This function behaves the same as `linestamp-mode:add-missing-timetstamps',
except instead of accepting a range within the current buffer, this function
starts at the end of the buffer and walks backwards adding timestamps to any
lines which do not have them already.  It stops when it finds the first line
which already has a timestamp."
  ;; Do nothing unless `linestamp-mode' is turned on
  (when (bound-and-true-p linestamp-mode)
    ;; Operate on this buffer in a temporary, unrestricted context
    (save-restriction
      (widen)
      (save-excursion
        ;; Walk backwards from the end of the buffer, adding timestamps until we
        ;; find a line that already has a timestamp
        (loop initially (goto-char (point-max))
              until (bobp)
              until (linestamp-mode:-get-overlays-on-line)
              do (linestamp-mode:-add-overlay-to-line placeholder?)
              do (forward-line -1))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Internals
;;

(defun linestamp-mode:-true-point-at-bol ()
"Returns the \"true\" beginning-of-line position.  This is generally the same
as `point-at-bol', except when a mode (such as `comint-mode') has customized
this behavior (in the case of `comint-mode', the behavior is customized to keep
the cursor to the right of the shell prompt).  When `linestamp-mode' needs to
create an overlay with display text at the beginning of the line, it needs to
use the actual beginning-of-line position."
  (save-excursion
    (save-match-data
      (re-search-backward "^" nil t)
      (point))))

(defun linestamp-mode:-remove-overlays (beginning end)
"Removes all `linestamp-mode' overlays between BEGINNING and END"
  (remove-overlays beginning end 'timestamp? t))

(defun linestamp-mode:-remove-overlays-on-line ()
"Removes all `linestamp-mode' overlays from the current line"
  (linestamp-mode:-remove-overlays (linestamp-mode:-true-point-at-bol)
                                   (point-at-eol)))

(defun linestamp-mode:-remove-all-overlays ()
"Removes all `linestamp-mode' overlays from the current buffer"
  ;; Operate on this buffer in a temporary, unrestricted context
  (save-restriction
    (widen)
    (save-excursion
      (linestamp-mode:-remove-overlays (point-min) (point-max)))))

(defun linestamp-mode:-get-overlays-on-line ()
"Returns a list of all `linestamp-mode' overlays on the current line"
  (--select (overlay-get it 'timestamp?)
            (overlays-in (linestamp-mode:-true-point-at-bol)
                         (point-at-eol))))

(defun linestamp-mode:-add-overlay-to-line (&optional placeholder?)
"Adds a `linestamp-mode' overlay to the current line"
  ;; Get the prefix string to use for the current line
  (let* ((prefix-string (if placeholder?
                            (apply linestamp-mode:placeholder-string-function ())
                          (apply linestamp-mode:timestamp-string-function ())))
         ;; Create a display-string for the prefix, which will be attached
         ;; to the overlay we create
         (display-string (if linestamp-mode:timestamp-margin
                             (list (list 'margin linestamp-mode:timestamp-margin)
                                   prefix-string)
                           (list prefix-string)))
         ;; Create a dummy string with a 'display property set to the actual
         ;; string we want to display
         (before-string (propertize " " 'display display-string))
         ;; Create an overlay at the beginning of this line
         (bol (linestamp-mode:-true-point-at-bol))
         (overlay (make-overlay bol bol)))
    ;; Set the overlay to use the dummy string defined above (which has the real
    ;; string embedded in the 'display property)
    (overlay-put overlay 'before-string before-string)
    ;; Mark this overly so we remember that it's ours
    (overlay-put overlay 'timestamp? t)))

(defun linestamp-mode:-update-timetstamps (beginning end)
"Updates timestamp overlays on each line in the area specified by BEGINNING and
END, adding them if necessary."
  ;; Operate on this buffer in a temporary, unrestricted context
  (save-restriction
    (widen)
    (save-excursion
      ;; Note: we can't just call `remove-overlays' once specifying beginning
      ;; and end as the boundaries of the region, since we actually need to
      ;; remove any overlay from any line intersecting the region
      (loop initially (goto-char beginning)
            while (<= (point) end)
            until (eobp)
            do (linestamp-mode:-remove-overlays-on-line)
            do (linestamp-mode:-add-overlay-to-line)
            do (forward-line)))))

(defun linestamp-mode:-after-change-function (beginning end length)
"Hook function for `after-change-functions' which updates timestamp overlays
for all lines within the changed area"
  (run-hooks 'linestamp-mode:before-update-hook)
  (linestamp-mode:-update-timetstamps beginning end)
  (run-hooks 'linestamp-mode:after-update-hook))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(provide 'linestamp-mode)
;;; linestamp-mode.el ends here
