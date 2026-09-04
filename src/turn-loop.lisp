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
:on-turn-complete; tool calls are dispatched through the registry.

Dynamically binds *CURRENT-AGENT* so tools (and hook handlers) can
introspect on the agent whose turn they're handling."
  (let* ((*current-agent* agent)
         (rewritten (run-hook :on-user-input agent msg)))
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


(defun %messages-list-p (m)
  "T if M is a list of message plists, each carrying :role and :content.
Used by provider drivers to dispatch on the multi-step messages-list
shape vs. the legacy single-message shape that provider-stream! used to
require. Defined here in turn-loop.lisp because it's protocol-level."
  (and (listp m)
       (consp m)
       (every (lambda (e) (and (listp e) (getf e :role) (getf e :content))) m)))

(defun %last-user-content-from-messages (messages)
  "Pull the latest 'user' role :content out of a messages-list. Used by
single-step providers (e.g. stub-provider) so they can ignore the rest
of the conversation history and just respond to the most recent prompt."
  (loop for m in (reverse messages)
        when (and (string= "user" (getf m :role))
                  (stringp (getf m :content)))
          return (getf m :content)))

(defparameter *max-tool-use-iterations* 16
  "Safety bound on the multi-step tool-use loop in drive-stream. After
this many provider round-trips the loop exits even if the model is still
emitting tool_use blocks. Prevents accidental infinite spend.")

(defparameter *invalid-tool-arguments-marker* (gensym "INVALID-TOOL-ARGUMENTS-")
  "Unforgeable marker used by provider decoders after argument failure.")

(defun %invalid-tool-arguments-p (args)
  (and (consp args) (eq (first args) *invalid-tool-arguments-marker*)))

(defun %consume-stream (stream)
  "Drain STREAM into a step plist:
  (:text-parts (\"...\" ...)        ; assistant text fragments in order
   :tool-uses ((:id ID :name NAME :args ARGS) ...)
   :assistant-content RAW           ; opaque, provider's round-trip blob
   :stop-reason :tool-use|:end-turn|:max-tokens|:error|nil
   :error PLIST-OR-NIL)
The provider may emit frames in any order; we accumulate until :done."
  (let ((text-parts nil) (tool-uses nil) (assistant-content nil)
        (stop-reason nil) (err nil))
    (loop for frame = (stream-next-frame! stream)
          until (eq frame :done)
          do (case (and (consp frame) (first frame))
               (:text              (push (second frame) text-parts))
               (:tool-use          (push (list :id (second frame)
                                               :name (third frame)
                                               :args (fourth frame))
                                         tool-uses))
               (:assistant-content (setf assistant-content (second frame)))
               (:stop-reason       (setf stop-reason (second frame)))
               (:error             (setf err (rest frame)))))
    (list :text-parts        (nreverse text-parts)
          :tool-uses         (nreverse tool-uses)
          :assistant-content assistant-content
          :stop-reason       stop-reason
          :error             err)))

(defun %dispatch-tool-use (agent tool-use)
  "Convert one (:id :name :args) plist into a tool-result plist via the
existing :on-tool-call hook + dispatch path."
  (handle-tool-frame agent (list :tool-use (getf tool-use :id)
                                 (getf tool-use :name) (getf tool-use :args))))

(defun drive-stream (agent msg)
  "Multi-step provider loop with tool_result feedback and conversation
history. For each iteration:

  1. Build a messages list = agent's prior history + current user content.
  2. provider-stream!, drain, get a step plist.
  3. Append assistant-content to messages.
  4. If stop-reason is :tool-use, dispatch each tool-use, add a user
     message of tool_result blocks (provider-specific shape via
     tool-results-message-content), loop. Else stop.
  5. Persist the final messages list back to agent-message-history.

Returns a reply plist. Bounded by *MAX-TOOL-USE-ITERATIONS* to prevent
runaway spend."
  (let ((provider (agent-provider agent)))
    (when (null provider)
      (return-from drive-stream
        (make-reply "" :tool-results (list (list :error :no-provider)))))
    (let* ((initial-content (cond
                              ((and (listp msg) (ask-content msg))
                               (ask-content msg))
                              ((stringp msg) msg)
                              (t (princ-to-string msg))))
           (history (copy-list (agent-message-history agent)))
           (messages (append history
                             (list (list :role "user"
                                         :content initial-content))))
           (final-text (make-string-output-stream))
           (all-tool-results nil))
      (loop for iteration from 1 to *max-tool-use-iterations*
            for stream = (provider-stream! provider agent messages)
            for step   = (%consume-stream stream)
            do
               (dolist (part (getf step :text-parts))
                 (write-string part final-text))
               (when (getf step :error)
                 (push (list :error (getf step :error)) all-tool-results))
               ;; Append the assistant message verbatim (raw content, not text)
               (when (getf step :assistant-content)
                 (setf messages
                       (append messages
                               (list (list :role "assistant"
                                           :content (getf step :assistant-content))))))
               (cond
                 ;; Provider returned tool-uses; try to continue the loop.
                 ((and (eq (getf step :stop-reason) :tool-use)
                       (getf step :tool-uses))
                  (let* ((results (mapcar
                                    (lambda (tu) (%dispatch-tool-use agent tu))
                                    (getf step :tool-uses)))
                         (tr-content
                           (handler-case
                               (tool-results-message-content provider results)
                             (error () nil))))
                    (setf all-tool-results (append all-tool-results results))
                    (cond
                      ;; Provider supports tool-result feedback: feed back, loop.
                      (tr-content
                       (setf messages
                             (append messages
                                     (list (list :role "user"
                                                 :content tr-content)))))
                      ;; No tool-result feedback shape defined for this
                      ;; provider — treat tool-use as terminal (legacy
                      ;; single-shot semantics; e.g. stub-provider in M4
                      ;; tests). Persist history and return.
                      (t
                       (setf (agent-message-history agent) messages)
                       (return (make-reply (get-output-stream-string final-text)
                                           :tool-results all-tool-results))))))
                 ;; Done
                 (t
                  (setf (agent-message-history agent) messages)
                  (return (make-reply (get-output-stream-string final-text)
                                      :tool-results all-tool-results))))
            finally
               ;; Hit the iteration cap
               (setf (agent-message-history agent) messages)
               (return (make-reply
                         (concatenate 'string
                                      (get-output-stream-string final-text)
                                      (format nil "~%[hit *max-tool-use-iterations*=~D]"
                                              *max-tool-use-iterations*))
                         :tool-results all-tool-results))))))

(defun handle-tool-frame (agent frame)
  "Run :on-tool-call and return an even-length tool-result plist."
  (destructuring-bind (_ id name args) frame
    (declare (ignore _))
    (if (%invalid-tool-arguments-p args)
        (list :id id :name name :status :error
              :error (format nil "Malformed tool arguments: ~A" (second args)))
        (let ((gated (run-hook :on-tool-call agent
                               (list :id id :name name :args args))))
          (if (eq gated :veto)
              (list :id id :name name :status :vetoed)
              (let ((args* (getf gated :args))
                    (name* (or (getf gated :name) name)))
                (multiple-value-bind (dispatch-name authorized-p)
                    (%authorized-agent-tool-name name*)
                  (if (not authorized-p)
                      (list :id id :name name* :status :unauthorized)
                      (handler-case
                          (list :id id :name name* :status :ok
                                :value (dispatch-tool! dispatch-name args*))
                        (unauthorized-tool-call ()
                          (list :id id :name name* :status :unauthorized))
                        (error (c)
                          (list :id id :name name* :status :error
                                :error (princ-to-string c))))))))))))

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
