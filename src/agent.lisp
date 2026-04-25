;;;; agent.lisp — base CLOS class + lifecycle defgenerics
;;;;
;;;; The base AGENT class carries the slots every supervised actor needs:
;;;; identity, capability, mailbox, parent supervisor, provider, tools,
;;;; system prompt, theory handle. Subclasses customise via DEFMETHOD on
;;;; the four lifecycle defgenerics: TURN-LOOP, HANDLE-MESSAGE, ON-SPAWN,
;;;; ON-SHUTDOWN. Live redefinition of any method takes effect on the
;;;; next dispatch (REQ-004).
;;;;
;;;; The default TURN-LOOP here is a placeholder that just consumes its
;;;; mailbox and dispatches to HANDLE-MESSAGE. The richer turn loop with
;;;; provider streaming and tool dispatch arrives in M4 (turn-loop.lisp).

(in-package #:anuna-imago)

(defclass agent ()
  ((id            :initarg :id            :reader agent-id)
   (capability    :initarg :capability    :reader agent-capability)
   (mailbox       :initform (make-mailbox) :reader agent-mailbox)
   (supervisor    :initarg :supervisor    :accessor agent-supervisor :initform nil)
   (provider      :initarg :provider      :accessor agent-provider   :initform nil)
   (tools         :initform nil           :accessor agent-tools)
   (system-prompt :initarg :system-prompt :accessor agent-system-prompt :initform "")
   (theory        :initarg :theory        :accessor agent-theory     :initform nil)
   (state         :initform :initialised  :accessor agent-state)))

(defmethod print-object ((a agent) stream)
  (print-unreadable-object (a stream :type t :identity t)
    (format stream "~A cap=~A state=~A"
            (agent-id a) (agent-capability a) (agent-state a))))

;; ----------------------------------------------------- lifecycle generics ---

(defgeneric turn-loop (agent ctx)
  (:documentation
   "Main per-message processing loop. The default M1 implementation drains
the agent's mailbox and dispatches to HANDLE-MESSAGE; M4 replaces this
with the provider-streaming loop. Live redefinition is supported per
REQ-004 — the next dispatch picks up the new method."))

(defgeneric handle-message (agent message)
  (:documentation
   "Handle a single inbound message. The base method ignores the message;
override in subclasses or via :around methods."))

(defgeneric on-spawn (agent)
  (:documentation
   "Lifecycle hook: agent has just been started by its supervisor. The
default sets state to :running; subclasses may extend via :after."))

(defgeneric on-shutdown (agent reason)
  (:documentation
   "Lifecycle hook: agent is about to stop. REASON is :normal, a list
beginning with :error, or a supervisor-supplied keyword. The default
sets state to :stopped; override or extend via :before."))

;; ----------------------------------------------------- default methods ---

(defmethod handle-message ((agent agent) message)
  (declare (ignore message))
  (values))

(defmethod on-spawn ((agent agent))
  (setf (agent-state agent) :running))

(defmethod on-shutdown ((agent agent) reason)
  (declare (ignore reason))
  (setf (agent-state agent) :stopped))

(defmethod turn-loop ((agent agent) ctx)
  "Default M1 turn loop: drain mailbox, dispatch to HANDLE-MESSAGE.
The richer streaming/tool-dispatch loop lives in turn-loop.lisp (M4)
and overrides this method."
  (declare (ignore ctx))
  (on-spawn agent)
  (unwind-protect
       (loop for msg = (receive! (agent-mailbox agent))
             do (cond
                  ((eq msg :closed) (return))
                  ((eq msg :shutdown) (return))
                  (t (handle-message agent msg))))
    (on-shutdown agent :normal)))
