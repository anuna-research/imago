;;;; mailbox.lisp — per-agent CBCL mailbox
;;;;
;;;; Thread-safe FIFO with head/tail pointers (O(1) push and pop) guarded by
;;;; an sb-thread mutex and waitqueue. ADR-001 commits us to SBCL, so we use
;;;; sb-thread directly rather than bordeaux-threads — fewer deps, identical
;;;; capability surface.

(in-package #:anuna-imago)

(defclass mailbox ()
  ((head   :initform nil :accessor mailbox-head)
   (tail   :initform nil :accessor mailbox-tail)
   (count  :initform 0   :accessor mailbox-count)
   (closed :initform nil :accessor mailbox-closed)
   (lock   :initform (sb-thread:make-mutex     :name "mailbox-lock") :reader mailbox-lock)
   (cv     :initform (sb-thread:make-waitqueue :name "mailbox-cv")   :reader mailbox-cv)))

(defun make-mailbox ()
  "Create an empty mailbox."
  (make-instance 'mailbox))

(defmethod print-object ((mb mailbox) stream)
  (print-unreadable-object (mb stream :type t :identity t)
    (format stream "depth=~D~:[~; CLOSED~]" (mailbox-count mb) (mailbox-closed mb))))

(defun send! (mailbox message)
  "Enqueue MESSAGE; wake one waiting receiver. Errors if mailbox is closed."
  (sb-thread:with-mutex ((mailbox-lock mailbox))
    (when (mailbox-closed mailbox)
      (error "send! on closed mailbox"))
    (let ((cell (cons message nil)))
      (if (mailbox-tail mailbox)
          (setf (cdr (mailbox-tail mailbox)) cell)
          (setf (mailbox-head mailbox) cell))
      (setf (mailbox-tail mailbox) cell))
    (incf (mailbox-count mailbox))
    (sb-thread:condition-notify (mailbox-cv mailbox)))
  message)

(defun receive! (mailbox &key timeout)
  "Pop oldest message, blocking if empty.
   :timeout SECONDS — return :timeout if no message arrives in time.
   Returns :closed once mailbox is closed and drained."
  (sb-thread:with-mutex ((mailbox-lock mailbox))
    (loop
      (cond
        ((mailbox-head mailbox)
         (let ((msg (car (mailbox-head mailbox))))
           (setf (mailbox-head mailbox) (cdr (mailbox-head mailbox)))
           (unless (mailbox-head mailbox)
             (setf (mailbox-tail mailbox) nil))
           (decf (mailbox-count mailbox))
           (return msg)))
        ((mailbox-closed mailbox)
         (return :closed))
        (t
         (unless (sb-thread:condition-wait (mailbox-cv mailbox)
                                           (mailbox-lock mailbox)
                                           :timeout timeout)
           (return :timeout)))))))

(defun peek-mailbox (mailbox)
  "Return next message without consuming it, or NIL if empty."
  (sb-thread:with-mutex ((mailbox-lock mailbox))
    (when (mailbox-head mailbox)
      (car (mailbox-head mailbox)))))

(defun mailbox-depth (mailbox)
  "Current number of awaiting messages."
  (sb-thread:with-mutex ((mailbox-lock mailbox))
    (mailbox-count mailbox)))

(defun close-mailbox! (mailbox)
  "Close the mailbox: subsequent send! errors; receive! returns :closed once empty.
   Wakes all current waiters so they observe the closed state."
  (sb-thread:with-mutex ((mailbox-lock mailbox))
    (setf (mailbox-closed mailbox) t)
    (sb-thread:condition-broadcast (mailbox-cv mailbox))))
