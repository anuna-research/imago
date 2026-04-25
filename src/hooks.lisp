;;;; hooks.lisp — hook registry with sync-transformative and fire-and-forget
;;;; semantics. Implements CON-003.
;;;;
;;;; Hook keys the 2k variant ships are restricted to the operational set in
;;;; spec REQ-005. The two "deprecated by stance" keys (:on-prompt-build and
;;;; :on-stream-token) are EXCLUDED — register-hook errors on them. This is
;;;; the load-bearing stance enforcement called out in my SPEC-011 review.

(in-package #:anuna-imago)

;; ---------------------------------------------------------------- keys ---

(defparameter *hook-keys*
  '(:on-user-input :on-tool-call :on-turn-complete :on-agent-spawn :on-agent-crash)
  "Hook keys the 2k variant of SPEC-011 ships with declared semantics.")

(defparameter *excluded-hook-keys*
  '(:on-prompt-build :on-stream-token)
  "Hook keys the 2k variant explicitly drops (SPEC-011 REQ-005 'deprecated by
stance, retained as opt-in only' — the 2k cut treats them as out of scope).")

(defparameter *hook-semantics*
  '((:on-user-input    . :sync)
    (:on-tool-call     . :sync)
    (:on-turn-complete . :fire-and-forget)
    (:on-agent-spawn   . :sync)
    (:on-agent-crash   . :sync))
  "Per-key semantics: :sync threads a primary value through registered
handlers in registration order; :fire-and-forget dispatches handlers on
a worker pool and returns immediately.")

;; ---------------------------------------------------------- registry ---

(defvar *hook-registry* (make-hash-table :test 'eq)
  "hook-key → list of (handle . handler-function) cells in registration order.")

(defvar *hook-registry-lock* (sb-thread:make-mutex :name "hook-registry"))

;; ---------------------------------------------------- async worker pool ---

(defparameter *hook-async-pool-size* 4)
(defvar *hook-async-mailbox* nil)
(defvar *hook-async-workers*  nil)

(defun %ensure-hook-async-pool ()
  "Lazily start the fire-and-forget worker pool. Caller MUST hold
*hook-registry-lock*."
  (unless *hook-async-mailbox*
    (setf *hook-async-mailbox* (make-mailbox))
    (dotimes (i *hook-async-pool-size*)
      (push (sb-thread:make-thread
             (lambda () (%run-hook-async-worker))
             :name (format nil "hook-async-~D" i))
            *hook-async-workers*))))

(defun %run-hook-async-worker ()
  (loop
    (let ((task (receive! *hook-async-mailbox*)))
      (cond
        ((eq task :closed) (return))
        ((eq task :stop)   (return))
        ((functionp task)
         (handler-case (funcall task) (error () nil)))))))

(defun shutdown-hook-async-pool ()
  "Stop async workers. Idempotent. Used by drain-supervisor and tests."
  (sb-thread:with-mutex (*hook-registry-lock*)
    (when *hook-async-mailbox*
      (dotimes (i (length *hook-async-workers*))
        (handler-case (send! *hook-async-mailbox* :stop) (error () nil)))
      (setf *hook-async-workers* nil
            *hook-async-mailbox*  nil))))

;; --------------------------------------------------------- registration ---

(defun register-hook (key handler)
  "Register HANDLER for hook KEY. Returns an opaque handle for REMOVE-HOOK.
Errors if KEY is on the stance-excluded list, or unknown."
  (cond
    ((member key *excluded-hook-keys*)
     (error "Hook key ~S is excluded by the 2k stance (SPEC-011 REQ-005 deprecated keys dropped). Refusing registration." key))
    ((not (member key *hook-keys*))
     (error "Unknown hook key ~S. Known keys: ~S." key *hook-keys*))
    (t
     (let ((handle (gensym (format nil "HOOK-~A-" (symbol-name key)))))
       (sb-thread:with-mutex (*hook-registry-lock*)
         (setf (gethash key *hook-registry*)
               (append (gethash key *hook-registry*)
                       (list (cons handle handler)))))
       handle))))

(defun remove-hook (handle)
  "Remove the hook registered under HANDLE. Returns T on success, NIL if not found."
  (sb-thread:with-mutex (*hook-registry-lock*)
    (loop for key in *hook-keys*
          for hooks = (gethash key *hook-registry*)
          for filtered = (remove handle hooks :key #'car)
          when (and hooks (not (= (length hooks) (length filtered))))
            do (setf (gethash key *hook-registry*) filtered)
               (return-from remove-hook t)
          finally (return-from remove-hook nil))))

(defun list-hooks (&optional key)
  "Snapshot of registered hooks. Without KEY, returns alist of all keys."
  (sb-thread:with-mutex (*hook-registry-lock*)
    (cond
      (key (mapcar #'car (gethash key *hook-registry*)))
      (t   (loop for k being the hash-keys of *hook-registry*
                 collect (cons k (mapcar #'car (gethash k *hook-registry*))))))))

(defun clear-all-hooks ()
  "Wipe the entire registry. Used by tests and during shutdown."
  (sb-thread:with-mutex (*hook-registry-lock*)
    (clrhash *hook-registry*)))

;; ---------------------------------------------------------------- dispatch ---

(defun run-hook (key agent &rest args)
  "Invoke hook KEY with the given args.

Sync semantics: handlers run in registration order. Each handler is called
as (HANDLER AGENT VALUE EXTRA...), where VALUE is the threaded primary
(initially args[0]) and EXTRA is the rest. A handler may return :VETO to
abort the chain (run-hook returns :VETO), or a new VALUE that chains
forward. With no handlers, returns args[0]; with no args, returns NIL.

Fire-and-forget semantics: each handler is dispatched on the async worker
pool with the full arg list; run-hook returns NIL immediately."
  (let ((semantics (cdr (assoc key *hook-semantics*)))
        (handlers  (sb-thread:with-mutex (*hook-registry-lock*)
                     (copy-list (gethash key *hook-registry*)))))
    (case semantics
      (:sync
       (let ((value (first args))
             (extra (rest args)))
         (dolist (cell handlers value)
           (let ((result (apply (cdr cell) agent value extra)))
             (when (eq result :veto)
               (return-from run-hook :veto))
             (setf value result)))))
      (:fire-and-forget
       (when handlers
         (sb-thread:with-mutex (*hook-registry-lock*) (%ensure-hook-async-pool))
         (let ((all-args (cons agent args)))
           (dolist (cell handlers)
             (let ((handler (cdr cell)))
               (send! *hook-async-mailbox*
                      (lambda () (apply handler all-args)))))))
       nil)
      (t
       (error "run-hook: hook key ~S has no declared semantics." key)))))
