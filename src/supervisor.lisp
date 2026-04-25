;;;; supervisor.lisp — OTP-style :one-for-one supervisor for SBCL
;;;;
;;;; A supervisor owns a list of child-specs. Each child-spec carries a
;;;; thunk (start-fn) and bookkeeping (thread, restart timestamps, state).
;;;; When a child's body exits — normally or by erroring — the wrapper
;;;; (run-child-body) reports the exit on the supervisor's event mailbox.
;;;; A monitor thread reads events and restarts per :one-for-one policy
;;;; up to MAX-RESTARTS within WITHIN-SECONDS, then escalates.
;;;;
;;;; Per the 2k cut, only :one-for-one is implemented. The other three
;;;; OTP strategies (:one-for-all, :rest-for-one, :simple-one-for-one)
;;;; are deferred to v2.

(in-package #:anuna-imago)

;; ---------------------------------------------------------------- classes ---

(defclass supervisor ()
  ((id             :initarg :id :reader sup-id)
   (children       :initform nil :accessor sup-children)
   (lock           :initform (sb-thread:make-mutex :name "sup-lock") :reader sup-lock)
   (events         :initform (make-mailbox) :reader sup-events)
   (monitor-thread :initform nil :accessor sup-monitor-thread)
   (state          :initform :stopped :accessor sup-state)
   (parent         :initarg :parent :initform nil :reader sup-parent)
   (max-restarts   :initarg :max-restarts :initform 3 :reader sup-max-restarts)
   (within-seconds :initarg :within-seconds :initform 60 :reader sup-within-seconds)))

(defclass child-spec ()
  ((id       :initarg :id       :reader child-id)
   (start-fn :initarg :start-fn :reader child-start-fn)
   (thread   :initform nil      :accessor child-thread)
   (restarts :initform nil      :accessor child-restarts)
   (state    :initform :stopped :accessor child-state)))

(defmethod print-object ((s supervisor) stream)
  (print-unreadable-object (s stream :type t :identity t)
    (format stream "~A state=~A children=~D"
            (sup-id s) (sup-state s) (length (sup-children s)))))

;; ---------------------------------------------------------------- helpers ---

(defun make-supervisor (id &key (max-restarts 3) (within-seconds 60) parent)
  "Create a new supervisor named ID with the given restart-window policy."
  (make-instance 'supervisor
                 :id id :max-restarts max-restarts
                 :within-seconds within-seconds :parent parent))

(defun add-child! (supervisor id start-fn)
  "Register a child. Does NOT start it; call START-SUPERVISOR! after registering."
  (sb-thread:with-mutex ((sup-lock supervisor))
    (push (make-instance 'child-spec :id id :start-fn start-fn)
          (sup-children supervisor)))
  id)

(defun %trim-restarts (timestamps within)
  "Drop timestamps older than WITHIN seconds from now."
  (let ((cutoff (- (get-universal-time) within)))
    (remove-if (lambda (ts) (< ts cutoff)) timestamps)))

;; --------------------------------------------------------- child lifecycle ---

(defun %start-child! (supervisor spec)
  "Spawn child body in a thread. Caller MUST hold sup-lock."
  (let ((thr (sb-thread:make-thread
              (lambda () (%run-child-body supervisor spec))
              :name (format nil "child-~A" (child-id spec)))))
    (setf (child-thread spec) thr)
    (setf (child-state spec) :running)))

(defun %run-child-body (supervisor spec)
  "Run user thunk; report exit to supervisor regardless of how it ends."
  (let ((reason :normal))
    (unwind-protect
         (handler-case (funcall (child-start-fn spec))
           (error (c) (setf reason (list :error c))))
      (handler-case
          (send! (sup-events supervisor)
                 (list :child-exit (child-id spec) reason))
        (error () nil)))))                  ; supervisor may already be closing

(defun %handle-child-exit (supervisor child-id reason)
  "React to a child exit per :one-for-one policy. Caller is the monitor thread."
  (sb-thread:with-mutex ((sup-lock supervisor))
    (let ((spec (find child-id (sup-children supervisor) :key #'child-id)))
      (when spec
        (cond
          ((eq reason :normal)
           (setf (child-state spec) :stopped))
          (t
           (push (get-universal-time) (child-restarts spec))
           (setf (child-restarts spec)
                 (%trim-restarts (child-restarts spec)
                                 (sup-within-seconds supervisor)))
           (cond
             ((>= (length (child-restarts spec)) (sup-max-restarts supervisor))
              (%escalate supervisor spec reason))
             (t
              (%start-child! supervisor spec)))))))))

(defun %escalate (supervisor spec reason)
  "Restart limit exceeded — set :failed, terminate siblings, exit monitor.
   Caller MAY be the monitor thread itself; we do NOT join from here."
  (declare (ignore spec))
  (setf (sup-state supervisor) :failed)
  (when (sup-parent supervisor)
    (handler-case
        (send! (sup-events (sup-parent supervisor))
               (list :child-exit (sup-id supervisor)
                     (list :restart-limit-exceeded reason)))
      (error () nil)))
  (%terminate-children! supervisor))

(defun %terminate-children! (supervisor)
  "Kill all live child threads. Caller holds sup-lock."
  (dolist (spec (sup-children supervisor))
    (let ((thr (child-thread spec)))
      (when (and thr (sb-thread:thread-alive-p thr)
                 (not (eq thr sb-thread:*current-thread*)))
        (handler-case (sb-thread:terminate-thread thr) (error () nil))
        (setf (child-state spec) :stopped)))))

;; ---------------------------------------------------------------- monitor ---

(defun %run-monitor (supervisor)
  "Monitor loop: process child-exit events until supervisor leaves :running."
  (loop
    (let ((evt (receive! (sup-events supervisor) :timeout 1)))
      (cond
        ((eq evt :timeout))                 ; periodic wake; check state below
        ((eq evt :closed) (return))
        ((and (consp evt) (eq (car evt) :child-exit))
         (%handle-child-exit supervisor (second evt) (third evt)))
        ((eq evt :shutdown) (return))))
    (unless (eq (sup-state supervisor) :running)
      (return))))

;; ---------------------------------------------------------- start / drain ---

(defun start-supervisor! (supervisor)
  "Start the supervisor and all registered children."
  (sb-thread:with-mutex ((sup-lock supervisor))
    (when (eq (sup-state supervisor) :running)
      (return-from start-supervisor! supervisor))
    (setf (sup-state supervisor) :running)
    (setf (sup-monitor-thread supervisor)
          (sb-thread:make-thread (lambda () (%run-monitor supervisor))
                                 :name (format nil "sup-monitor-~A" (sup-id supervisor))))
    (dolist (spec (sup-children supervisor))
      (%start-child! supervisor spec)))
  supervisor)

(defun drain-supervisor! (supervisor &key (timeout 30))
  "Stop all children gracefully, then the monitor thread.
   Safe to call from any thread except the monitor itself; if called from
   the monitor, the join step is skipped (monitor exits naturally)."
  (sb-thread:with-mutex ((sup-lock supervisor))
    (unless (member (sup-state supervisor) '(:stopped))
      (setf (sup-state supervisor) :draining))
    (%terminate-children! supervisor))
  (let ((mon (sup-monitor-thread supervisor)))
    (when (and mon
               (not (eq sb-thread:*current-thread* mon))
               (sb-thread:thread-alive-p mon))
      (handler-case (send! (sup-events supervisor) :shutdown) (error () nil))
      (handler-case
          (sb-thread:join-thread mon
                                 :timeout timeout
                                 :default :timeout)
        (error () nil))))
  (sb-thread:with-mutex ((sup-lock supervisor))
    (setf (sup-state supervisor) :stopped))
  supervisor)

;; -------------------------------------------------------- introspection ---

(defun list-children (supervisor)
  "Snapshot of child states. Returns plist per child."
  (sb-thread:with-mutex ((sup-lock supervisor))
    (mapcar (lambda (s)
              (list :id (child-id s)
                    :state (child-state s)
                    :restarts (length (child-restarts s))))
            (sup-children supervisor))))

(defun child-state-of (supervisor child-id)
  "Return the :state of CHILD-ID, or NIL if unknown."
  (sb-thread:with-mutex ((sup-lock supervisor))
    (let ((spec (find child-id (sup-children supervisor) :key #'child-id)))
      (when spec (child-state spec)))))

(defun force-restart! (supervisor child-id)
  "Terminate CHILD-ID's current thread (if any) and start it again.
   Restart timestamps are NOT bumped — this is an operator action, not a crash."
  (sb-thread:with-mutex ((sup-lock supervisor))
    (let ((spec (find child-id (sup-children supervisor) :key #'child-id)))
      (when spec
        (let ((thr (child-thread spec)))
          (when (and thr (sb-thread:thread-alive-p thr))
            (handler-case (sb-thread:terminate-thread thr) (error () nil))))
        (%start-child! supervisor spec)
        child-id))))
