;;;; turn-loop.lisp — default turn-loop method (M4)
;;;;
;;;; Replaces the M1 stub method on (turn-loop AGENT CTX) with the rich loop
;;;; that wires hooks, drives a provider stream, dispatches tool calls, and
;;;; sends a reply to the inbound message's :reply-to mailbox.
;;;;
;;;; Inbound messages are plists with the shape
;;;;   (:type :ask :content STRING :reply-to MAILBOX [:meta ALIST])
;;;; The harness convention treats anything else as a no-op (logged via
;;;; on-shutdown if it propagates errors). Once the gateway lands at M7,
;;;; messages will be parsed CBCL frames; the shape stays compatible.
;;;;
;;;; Provider abstraction (CON-005, minimal subset for M4):
;;;;   (provider-stream! PROVIDER AGENT MESSAGE) → STREAM
;;;;   (stream-next-frame! STREAM)               → FRAME | :done
;;;; A FRAME is one of:
;;;;   (:text  STRING)
;;;;   (:tool-use ID NAME ARGS-PLIST)
;;;;   (:error PLIST)
;;;; Closing a stream is implicit when :done is yielded.

(in-package #:anuna-imago)

;; ---------------------------------------------------- provider protocol ---

(defclass provider () ()
  (:documentation "Base class for LLM provider drivers (CON-005)."))

(defgeneric provider-name (provider)
  (:documentation "Short identifier, e.g. \"anthropic\", \"stub\".")
  (:method ((p provider)) "unknown"))

(defgeneric provider-stream! (provider agent message)
  (:documentation
   "Open a stream against PROVIDER for AGENT processing MESSAGE. Returns a
stream object that responds to STREAM-NEXT-FRAME!. Subclasses implement."))

(defgeneric stream-next-frame! (stream)
  (:documentation
   "Pull the next frame from STREAM. Returns one of:
  (:text STRING)
  (:tool-use ID NAME ARGS-PLIST)
  (:error PLIST)
  :done   — stream complete; subsequent calls also return :done."))

;; --------------------------------------------------- ask / reply helpers ---

(defun make-ask (content &key reply-to meta)
  "Build a canonical inbound ask message."
  (list :type :ask :content content :reply-to reply-to :meta meta))

(defun ask-message-p (msg)
  (and (listp msg) (eq :ask (getf msg :type))))

(defun ask-content (msg) (getf msg :content))
(defun ask-reply-to (msg) (getf msg :reply-to))

(defun make-reply (text &key tool-results meta)
  (list :type :reply :text text :tool-results tool-results :meta meta))

;; -------------------------------------------------------- single turn ---

(defun process-turn (agent msg)
  "Process one inbound message. Caller has already verified it's not a
control sentinel. Hooks fire at :on-user-input, :on-tool-call,
:on-turn-complete; tool calls are dispatched through the registry."
  (let ((rewritten (run-hook :on-user-input agent msg)))
    (cond
      ((eq rewritten :veto)
       (run-hook :on-turn-complete agent)
       :vetoed)
      (t
       (let ((reply (drive-stream agent rewritten)))
         (when (and (ask-message-p rewritten) (ask-reply-to rewritten))
           (handler-case (send! (ask-reply-to rewritten) reply)
             (error () nil)))
         (run-hook :on-turn-complete agent)
         reply)))))

(defun drive-stream (agent msg)
  "Open a provider stream, consume frames, dispatch tool calls, build reply."
  (let ((provider (agent-provider agent))
        (text     (make-string-output-stream))
        (tools    nil))
    (when (null provider)
      (return-from drive-stream
        (make-reply "" :tool-results
                    (list (list :error :no-provider)))))
    (let ((stream (provider-stream! provider agent msg)))
      (loop for frame = (stream-next-frame! stream)
            until (eq frame :done)
            do (case (and (consp frame) (first frame))
                 (:text
                  (write-string (second frame) text))
                 (:tool-use
                  (let ((tool-result (handle-tool-frame agent frame)))
                    (push tool-result tools)))
                 (:error
                  (push (list :error (rest frame)) tools)))))
    (make-reply (get-output-stream-string text)
                :tool-results (nreverse tools))))

(defun handle-tool-frame (agent frame)
  "Run :on-tool-call, dispatch the named tool, return a result plist.
The plist shape is (:id ID :name NAME :status STATUS [...]) — even-length,
suitable for GETF. The reply's :tool-results carries a list of these."
  (destructuring-bind (_ id name args) frame
    (declare (ignore _))
    (let ((gated (run-hook :on-tool-call agent
                           (list :id id :name name :args args))))
      (cond
        ((eq gated :veto)
         (list :id id :name name :status :vetoed))
        (t
         (let ((args* (getf gated :args))
               (name* (or (getf gated :name) name)))
           (handler-case
               (list :id id :name name*
                     :status :ok
                     :value (dispatch-tool! name* args*))
             (error (c)
               (list :id id :name name*
                     :status :error
                     :error (princ-to-string c))))))))))

;; --------------------------------------------------------- turn-loop ---

(defmethod turn-loop ((agent agent) ctx)
  "Default M4 turn loop. Replaces the M1 stub. Each inbound message drives
one turn through the provider; replies (when :reply-to is set) go back to
the caller's mailbox; :on-turn-complete fires fire-and-forget after every
turn including vetoed ones."
  (declare (ignore ctx))
  (run-hook :on-agent-spawn agent agent)
  (on-spawn agent)
  (unwind-protect
       (loop
         (let ((msg (receive! (agent-mailbox agent))))
           (cond
             ((eq msg :closed)   (return))
             ((eq msg :shutdown) (return))
             ((null msg)         (return))   ; spurious wakeup
             (t (handler-case (process-turn agent msg)
                  (error (c)
                    (run-hook :on-agent-crash agent c)))))))
    (on-shutdown agent :normal)))

;; --------------------------------------- spawn / ask convenience ---

(defun spawn-agent! (supervisor agent)
  "Register AGENT as a supervised child whose body is its turn-loop, then
ensure the supervisor is running. Returns the agent."
  (add-child! supervisor (agent-id agent)
              (lambda () (turn-loop agent nil)))
  (when (eq (sup-state supervisor) :stopped)
    (start-supervisor! supervisor))
  agent)

(defun ask-agent (agent content &key (timeout 5))
  "Send an ask and block for the reply (or :timeout). Convenience for tests
and REPL use; production callers should send the ask asynchronously and
read from the reply mailbox themselves."
  (let ((reply-mb (make-mailbox)))
    (send! (agent-mailbox agent)
           (make-ask content :reply-to reply-mb))
    (receive! reply-mb :timeout timeout)))
