;;; pomm.el --- Yet another Pomodoro timer implementation -*- lexical-binding: t -*-

;; Copyright (C) 2021 Korytov Pavel

;; Author: Korytov Pavel <thexcloud@gmail.com>
;; Maintainer: Korytov Pavel <thexcloud@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (alert "1.2") (seq "2.22") (transient "0.2.0"))
;; Homepage: https://github.com/SqrtMinusOne/pomm.el

;; This file is NOT part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; TODO

;;; Code:
(require 'alert)
(require 'seq)
(require 'eieio)
(require 'transient)

(defgroup pomm nil
  "Yet another Pomodoro timer implementation."
  :group 'tools)

(defcustom pomm-work-period 25
  "Number of minutes for a work period."
  :group 'pomm
  :type 'integer)

(defcustom pomm-short-break-period 5
  "Number of minutes for a break period."
  :group 'pomm
  :type 'integer)

(defcustom pomm-long-break-period 25
  "Number of minutes for a long break period."
  :group 'pomm
  :type 'integer)

(defcustom pomm-number-of-periods 4
  "Number of periods before a long break."
  :group 'pomm
  :type 'integer)

(defcustom pomm-short-break-message "Take a short break!"
  "Message for a start of a short break period."
  :group 'pomm
  :type 'string)

(defcustom pomm-long-break-message "Take a longer break!"
  "Message for a start of a long break period."
  :group 'pomm
  :type 'string)

(defcustom pomm-ask-before-long-break t
  "Ask a user whether to do a long break or stop the pomodoros."
  :group 'pomm
  :type 'boolean)

(defcustom pomm-work-message "Time for work!"
  "Message for a start of a work period."
  :group 'pomm
  :type 'string)

(defcustom pomm-state-file-location
  (concat user-emacs-directory "pomm")
  "Location of the pomm state file."
  :group 'pomm
  :type 'string)

(defcustom pomm-remaining-time-format "%m:%.2s"
  "Format the time, remaining in the period.

The format is the same as in `format-seconds'"
  :group 'pomm
  :type 'string)

(defcustom pomm-on-tick-hook nil
  "A hook to run on every tick when the timer is running."
  :group 'pomm
  :type 'hook)

(defcustom pomm-on-status-changed-hook nil
  "A hook to run on status change."
  :group 'pomm
  :type 'hook)

(defvar pomm--state nil
  "Current state of pomm.el.

This is an alist of with the following keys:
- status: either 'stopped, 'paused or 'running
- current: an alist with a current period
- history: a list with today's history
- last-changed-time: a timestamp of a last change in status

Current period is also an alist with the following keys:
- kind: either 'short-break, 'long-break or 'work
- start-time: start timestamp
- effective-start-time: start timestamp, corrected for pauses
- iteration: number the current pomodoro iteration

History is a list of alists with the following keys:
- kind: same as in current
- iteration
- start-time: start timestamp
- end-time: end timestamp
- paused-time: time spent it a paused state")

(defvar pomm--timer nil
  "A variable for the pomm timer.")

(defvar pomm-current-mode-line-string nil
  "Current mode-line string of the pomodoro timer.

Updated by `pomm-update-mode-line-string'.")

(defun pomm--do-reset ()
  "Reset the pomodoro timer state."
  (when pomm--timer
    (cancel-timer pomm--timer)
    (setq pomm--timer nil))
  ;; This is necessary to make the reset work with setf on the variable
  (setq pomm--state
        `((status . ,'stopped)
          (current . ,nil)
          (history . ,nil)
          (last-changed-time ,(time-convert nil 'integer)))
        pomm-current-mode-line-string "")
  (setf (alist-get 'status pomm--state) 'stopped))

(defun pomm--init-state ()
  "Initialize the pomodoro timer state."
  (pomm--do-reset))                     ;; TODO

(defun pomm-reset ()
  "Reset the pomodoro timer."
  (interactive)
  (when (y-or-n-p "Are you sure you want to reset the Pomodoro timer? ")
    (pomm--do-reset)))

(defun pomm--dispatch-notification (kind)
  "Dispatch a notification about a start of a period.

KIND is the same as in `pomm--state'"
  (alert
   (pcase kind
     ('short-break pomm-short-break-message)
     ('long-break pomm-long-break-message)
     ('work pomm-work-message))
   :title "Pomodoro"))

(defun pomm--new-iteration ()
  "Start a new iteration of the pomodoro timer."
  (setf (alist-get 'current pomm--state)
        `((kind . work)
          (start-time . ,(time-convert nil 'integer))
          (effective-start-time . ,(time-convert nil 'integer))
          ;; Maximum iteration in history + 1 or 0
          (iteration . ,(1+ (seq-max
                             (cons 0
                                   (mapcar
                                    (lambda (h) (alist-get 'iteration h))
                                    (alist-get 'history pomm--state)))))))
        (alist-get 'last-changed-time pomm--state) (time-convert nil 'integer)
        (alist-get 'status pomm--state) 'running)
  (pomm--dispatch-notification 'work))

(defun pomm--get-kind-length (kind)
  "Get a length of period KIND in seconds."
  (* 60
     (pcase kind
       ('short-break pomm-short-break-period)
       ('long-break pomm-long-break-period)
       ('work pomm-work-period)
       (_ 0))))

(defun pomm--need-switch-p ()
  "Check if it is necessary to switch a period.

The condition is: (effective-start-time + length) < now."
  (< (+ (alist-get 'effective-start-time (alist-get 'current pomm--state))
        (pomm--get-kind-length
         (alist-get 'kind (alist-get 'current pomm--state))))
     (time-convert nil 'integer)))

(defun pomm--store-current-to-history ()
  "Store the current pomodoro state to the history."
  (let* ((current-kind (alist-get 'kind (alist-get 'current pomm--state)))
         (current-iteration (alist-get 'iteration (alist-get 'current pomm--state)))
         (start-time (alist-get 'start-time (alist-get 'current pomm--state)))
         (end-time (time-convert nil 'integer))
         (paused-time (- end-time
                         start-time
                         (pomm--get-kind-length current-kind))))
    (push `((kind . ,current-kind)
            (iteration . ,current-iteration)
            (start-time . ,start-time)
            (end-time . ,end-time)
            (paused-time . ,paused-time))
          (alist-get 'history pomm--state))))

(defun pomm--switch-to-next ()
  "Switch to the next period."
  (let* ((current-kind (alist-get 'kind (alist-get 'current pomm--state)))
         (current-iteration (alist-get 'iteration (alist-get 'current pomm--state)))
         ;; Number of work periods in the current iteration
         (work-periods (+ (seq-count
                           (lambda (item)
                             (and (= (alist-get 'iteration item) current-iteration)
                                  (eq 'work (alist-get 'kind item))))
                           (alist-get 'history pomm--state))
                          (if (eq current-kind 'work) 1 0)))
         (next-kind (cond
                     ((and (eq current-kind 'work)
                           (>= work-periods pomm-number-of-periods))
                      'long-break)
                     ((and (eq current-kind 'work)
                           (< work-periods pomm-number-of-periods))
                      'short-break)
                     (t 'work)))
         (next-iteration (if (eq current-kind 'long-break)
                             (+ current-iteration 1)
                           current-iteration)))
    (pomm--store-current-to-history)
    (if (or (not (eq next-kind 'long-break))
            (not pomm-ask-before-long-break)
            (y-or-n-p "Start a long break (y) or end the pomodors (n)? "))
        (progn
          (setf (alist-get 'current pomm--state)
                `((kind . ,next-kind)
                  (start-time . ,(time-convert nil 'integer))
                  (effective-start-time . ,(time-convert nil 'integer))
                  (iteration . ,next-iteration)))
          (pomm--dispatch-notification next-kind))
      (setf (alist-get 'current pomm--state) nil)
      (setf (alist-get 'status pomm--state) 'stopped))))

(defun pomm--on-tick ()
  "A function to be ran on a timer tick."
  (pcase (alist-get 'status pomm--state)
    ('stopped (when pomm--timer
                (cancel-timer pomm--timer)
                (setq pomm--timer nil)))
    ('paused nil)
    ('running
     (progn
       (when (pomm--need-switch-p)
         (pomm--switch-to-next))
       (run-hooks 'pomm-on-tick-hook)))))

(defun pomm--get-time-remaning ()
  "Get time remaining in the current pomodoro period.

The formula is:
\(effective-start-time + length\) - now + paused-time,
where paused-time is 0 if status is not 'paused, otherwise:
paused-time := now - last-changed-time"
  (+
   (+ (or (alist-get 'effective-start-time (alist-get 'current pomm--state)) 0)
      (pomm--get-kind-length
       (alist-get 'kind (alist-get 'current pomm--state))))
   (- (time-convert nil 'integer))
   (if (eq (alist-get 'status pomm--state) 'paused)
       (+ (-
           (time-convert nil 'integer)
           (alist-get 'last-changed-time pomm--state)))
     0)))

(defun pomm-format-mode-line ()
  "Format a string for the mode line."
  (let ((current-status (alist-get 'status pomm--state)))
    (if (or (eq current-status 'stopped) (not (alist-get 'current pomm--state)))
        ""
      (let* ((current-kind (alist-get 'kind (alist-get 'current pomm--state)))
             (time-remaining (pomm--get-time-remaning)))
        (format "[%s] %s "
                (concat
                 (symbol-name current-kind)
                 (if (eq current-status 'paused)
                     ":paused"
                   ""))
                (format-seconds pomm-remaining-time-format time-remaining))))))

(defun pomm-update-mode-line-string ()
  "Update the modeline string for the pomodoro timer.

This sets the variable `pomm-current-mode-line-string' with a value
from `pomm-format-mode-line'.  This is made so to minimize the load on
the modeline, because otherwise updates may be quite frequent.

To add this to the modeline, add the following code to your config:
\(add-to-list 'mode-line-misc-info '\(:eval pomm-current-mode-line-string\)')
\(add-hook 'pomm-on-tick-hook 'pomm-update-mode-line-string\)
\(add-hook 'pomm-on-tick-hook 'force-mode-line-update\)
\(add-hook 'pomm-on-status-changed-hook 'pomm-update-mode-line-string\)
\(add-hook 'pomm-on-status-changed-hook 'force-mode-line-update)"
  (setq pomm-current-mode-line-string (pomm-format-mode-line)))

;;;###autoload
(defun pomm-start ()
  "Start or continue the pomodoro timer.

- If the timer is not initialized, initialize the state.
- If the timer is stopped, start a new iteration.
- If the timer is paused, unpause the timer."
  (interactive)
  (unless pomm--state
    (pomm--init-state))
  (cond
   ((eq (alist-get 'status pomm--state) 'stopped) (pomm--new-iteration))
   ((eq (alist-get 'status pomm--state) 'paused)
    (setf (alist-get 'status pomm--state) 'running
          (alist-get 'effective-start-time (alist-get 'current pomm--state))
          (+ (alist-get 'effective-start-time (alist-get 'current pomm--state))
             (- (time-convert nil 'integer) (alist-get 'last-changed-time pomm--state)))
          (alist-get 'last-changed-time pomm--state) (time-convert nil 'integer)))
   ((eq (alist-get 'status pomm--state) 'running) (message "The timer is running!")))
  (run-hooks 'pomm-on-status-changed-hook)
  (unless pomm--timer
    (setq pomm--timer (run-with-timer 0 1 'pomm--on-tick))))

(defun pomm-stop ()
  "Stop the current iteration of the pomodoro timer."
  (interactive)
  (if (eq (alist-get 'status pomm--state) 'stopped)
      (message "The timer is already stopped!")
    (pomm--store-current-to-history)
    (setf (alist-get 'status pomm--state) 'stopped
          (alist-get 'current pomm--state) nil
          (alist-get 'last-changed-time pomm--state) (time-convert nil 'integer))
    (run-hooks 'pomm-on-status-changed-hook)))

(defun pomm-pause ()
  "Pause the pomodoro timer."
  (interactive)
  (if (eq (alist-get 'status pomm--state) 'running)
      (progn
        (setf (alist-get 'status pomm--state) 'paused
              (alist-get 'last-changed-time pomm--state) (time-convert nil 'integer))
        (run-hooks 'pomm-on-status-changed-hook))
    (message "The timer is not running!")))

;;;; Transient
(transient-define-infix pomm--set-short-break-period ()
  :class 'transient-lisp-variable
  :variable 'pomm-short-break-period
  :key "-s"
  :description "Short break period (minutes):"
  :reader (lambda (&rest _)
            (read-number "Number of minutes for a short break period: "
                         pomm-short-break-period)))

(transient-define-infix pomm--set-long-break-period ()
  :class 'transient-lisp-variable
  :variable 'pomm-long-break-period
  :key "-l"
  :description "Long break period (minutes):"
  :reader (lambda (&rest _)
            (read-number "Number of minutes for a long break period: "
                         pomm-long-break-period)))

(transient-define-infix pomm--set-work-period ()
  :class 'transient-lisp-variable
  :variable 'pomm-work-period
  :key "-w"
  :description "Work period (minutes):"
  :reader (lambda (&rest _)
            (read-number "Number of minutes for a work period: "
                         pomm-work-period)))

(transient-define-infix pomm--set-number-of-periods ()
  :class 'transient-lisp-variable
  :variable 'pomm-number-of-periods
  :key "-p"
  :description "Number of work periods before long break: "
  :reader (lambda (&rest _)
            (read-number "Number of work periods before a long break:"
                         pomm-number-of-periods)))

(defclass pomm--transient-current (transient-suffix)
  (transient :initform t)
  "A transient class to display the current state of the timer.")

(cl-defmethod transient-init-value ((_ pomm--transient-current))
  "A dummy method for `pomm--transient-current'.

The class doesn't actually have any value, but this is necessary for transient."
  nil)

(defun pomm--get-kind-face (kind)
  "Get a face for a KIND of period.

KIND is the same as in `pomm--state'"
  (pcase kind
    ('work 'success)
    ('short-break 'warning)
    ('long-break 'error)))

(cl-defmethod transient-format ((_ pomm--transient-current))
  "Format the state of the pomodoro timer."
  (let ((status (alist-get 'status pomm--state)))
    (if (or (eq 'stopped status) (not (alist-get 'current pomm--state)))
        "The timer is not running"
      (let* ((kind (alist-get 'kind (alist-get 'current pomm--state)))
             (start-time (alist-get 'start-time (alist-get 'current pomm--state)))
             (iteration (alist-get 'iteration (alist-get 'current pomm--state)))
             (time-remaining (pomm--get-time-remaning)))
        (concat
         (format "Iteration #%d. " iteration)
         "State: "
         (propertize
          (upcase (symbol-name kind))
          'face
          (pomm--get-kind-face kind))
         (if (eq status 'paused)
             (propertize
              " [PAUSED]"
              'face 'warning)
           "")
         ". Started at: "
         (propertize
          (format-time-string "%H:%M:%S" (seconds-to-time start-time))
          'face 'success)
         ". Time remaining: "
         (propertize
          (format-seconds "%.2h:%.2m:%.2s" time-remaining)
          'face 'success))))))

(defclass pomm--transient-history (transient-suffix)
  (transient :initform t)
  "A transient class to display the history of the pomodoro timer.")

(cl-defmethod transient-init-value ((_ pomm--transient-history))
  "A dummy method for `pomm--transient-history'.

The class doesn't actually have any value, but this is necessary for transient."
  nil)

(cl-defmethod transient-format ((_ pomm--transient-history))
  "Format the history list for the transient buffer."
  (if (not (alist-get 'history pomm--state))
      "No history yet"
    (let ((previous-iteration -1))
      (mapconcat
       (lambda (item)
         (let ((kind (alist-get 'kind item))
               (iteration (alist-get 'iteration item))
               (start-time (alist-get 'start-time item))
               (end-time (alist-get 'end-time item))
               (paused-time (alist-get 'paused-time item)))
           (concat
            (if (> iteration previous-iteration)
                (progn (setq previous-iteration iteration) "\n") "")
            (format "[%02d] " iteration)
            (propertize
             (format "%12s  " (upcase (symbol-name kind)))
             'face (pomm--get-kind-face kind))
            (format-time-string "%H:%M" (seconds-to-time start-time))
            "-"
            (format-time-string "%H:%M" (seconds-to-time end-time)))))
       (alist-get 'history pomm--state)
       "\n"))))

(transient-define-infix pomm--transient-history-suffix ()
  :class 'pomm--transient-history
  ;; A dummy key. Seems to be necessary for transient.
  ;; Just don't press ~ while in buffer.
  :key "~~1")

(transient-define-infix pomm--transient-current-suffix ()
  :class 'pomm--transient-current
  :key "~~2")

(transient-define-prefix pomm-transient ()
  ["Settings"
   (pomm--set-short-break-period)
   (pomm--set-long-break-period)
   (pomm--set-work-period)
   (pomm--set-number-of-periods)]
  ["Commands"
   :class transient-row
   ("s" "Start the timer" pomm-start :transient t)
   ("S" "Stop the timer" pomm-stop :transient t)
   ("p" "Pause the timer" pomm-pause :transient t)
   ("R" "Reset" pomm-reset :transient t)
   ("u" "Update" (lambda () (interactive)) :transient t)
   ("q" "Quit" transient-quit-one)]
  ["Status"
   (pomm--transient-current-suffix)]
  ["History"
   (pomm--transient-history-suffix)])

;;;###autoload
(defun pomm ()
  "A Pomodoro timer.

This command initialized the state of timer and triggers the transient buffer."
  (interactive)
  (unless pomm--state
    (pomm--init-state))
  (call-interactively #'pomm-transient))

(provide 'pomm)
;;; pomm.el ends here
