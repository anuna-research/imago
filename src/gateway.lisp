;;;; gateway.lisp — CBCL Router Client (CON-001, M7)
;;;;
;;;; Connects an agent to a CBCL router. The gateway runs as a supervised
;;;; child: a connection thread holds the transport, a heartbeat thread
;;;; pings periodically, and inbound CBCL frames pump into the agent's
;;;; mailbox. Replies go back via SEND-REPLY!.
;;;;
;;;; Transport is abstract — defgenerics open!/send!/recv!/close! plus a
;;;; pre-connected? predicate. M7 ships MOCK-TRANSPORT (in-memory queue
;;;; pair) for tests; a websocket-driver implementation is a small wrapper
;;;; intended as a follow-up commit. The seam means the gateway logic is
;;;; testable end-to-end without a real WSS server in CI.
;;;;
;;;; State machine:
;;;;   :disconnected → :authenticating → :ready → (:draining → :disconnected)
;;;;                                            ↘ :failed (via parent supervisor)
;;;;
;;;; Wire format (per CON-001 + cbcl-rs FFI for parsing):
;;;;   Outbound auth:        (auth <identity-token>)
;;;;   Outbound register:    (register <dialect:verb>)
;;;;   Outbound reply:       (reply <receipt-id> <body-sexpr>)
;;;;   Outbound heartbeat:   (heartbeat)
;;;;   Outbound disconnect:  (disconnect)
;;;;   Inbound auth-ok:      (auth-ok <session-id>)
;;;;   Inbound register-ok:  (register-ok <capability>)
;;;;   Inbound ask:          (ask <receipt-id> <ask-body-sexpr>)
;;;;   Inbound pong:         (pong)
;;;;   Inbound error:        (error <reason>)

(in-package #:anuna-imago)

;; ----------------------------------------------------- transport protocol ---

(defgeneric transport-open! (transport)
  (:documentation "Open the underlying connection. Caller may block until ready."))

(defgeneric transport-send! (transport string)
  (:documentation "Send a CBCL frame (S-expression string). Atomic per call."))

(defgeneric transport-recv! (transport &key timeout)
  (:documentation "Receive next frame as a string, blocking up to TIMEOUT
seconds. Returns :TIMEOUT on timeout, :CLOSED if peer disconnected."))

(defgeneric transport-close! (transport)
  (:documentation "Close. Idempotent."))

(defgeneric transport-connected-p (transport))

;; ----------------------------------------------------- mock transport ---

(defclass mock-transport ()
  ((inbox      :initform (make-mailbox) :reader mock-transport-inbox
               :documentation "Frames arriving FROM the simulated router.")
   (outbox     :initform (make-mailbox) :reader mock-transport-outbox
               :documentation "Frames the gateway has sent (for tests to read).")
   (connected  :initform nil :accessor %mock-connected))
  (:documentation "In-memory transport: tests push to INBOX (simulating
router-side messages), read from OUTBOX (verifying gateway behaviour)."))

(defun make-mock-transport () (make-instance 'mock-transport))

(defmethod transport-open! ((tr mock-transport))
  (setf (%mock-connected tr) t))

(defmethod transport-send! ((tr mock-transport) string)
  (unless (%mock-connected tr) (error "transport-send! on closed mock"))
  (send! (mock-transport-outbox tr) string))

(defmethod transport-recv! ((tr mock-transport) &key timeout)
  (cond
    ((not (%mock-connected tr)) :closed)
    (t (receive! (mock-transport-inbox tr) :timeout timeout))))

(defmethod transport-close! ((tr mock-transport))
  (setf (%mock-connected tr) nil)
  (handler-case (close-mailbox! (mock-transport-inbox tr))  (error () nil))
  (handler-case (close-mailbox! (mock-transport-outbox tr)) (error () nil)))

(defmethod transport-connected-p ((tr mock-transport))
  (%mock-connected tr))

;; Test helpers (also useful at the REPL)
(defun mock-feed! (transport frame-string)
  "Inject FRAME-STRING into the gateway as if it arrived from the router."
  (send! (mock-transport-inbox transport) frame-string))

(defun mock-drain! (transport &key timeout)
  "Read the next frame the gateway sent. :TIMEOUT if none."
  (receive! (mock-transport-outbox transport) :timeout timeout))

;; ----------------------------------------------------- gateway ---

(defclass gateway ()
  ((id          :initarg :id          :reader gateway-id)
   (transport   :initarg :transport   :reader gateway-transport)
   (identity    :initarg :identity    :reader gateway-identity
                :documentation "Bearer token / agent identity string for auth.")
   (capability  :initarg :capability  :reader gateway-capability)
   (agent       :initarg :agent       :accessor gateway-agent :initform nil
                :documentation "Inbound asks pump into AGENT's mailbox.")
   (receipt-log :initarg :receipt-log :accessor gateway-receipt-log :initform nil)
   (state       :initform :disconnected :accessor gateway-state)
   (session     :initform nil :accessor gateway-session)
   (lock        :initform (sb-thread:make-mutex :name "gateway") :reader %gateway-lock)
   (recv-thread :initform nil :accessor %gateway-recv-thread)
   (heartbeat-thread :initform nil :accessor %gateway-heartbeat-thread)
   (stop-flag   :initform nil :accessor %gateway-stop-flag)
   (heartbeat-interval :initarg :heartbeat-interval :initform 30
                       :reader gateway-heartbeat-interval)))

(defun make-gateway (&key id transport identity capability agent receipt-log
                          (heartbeat-interval 30))
  (make-instance 'gateway
                 :id id :transport transport :identity identity
                 :capability capability :agent agent :receipt-log receipt-log
                 :heartbeat-interval heartbeat-interval))

(defmethod print-object ((g gateway) stream)
  (print-unreadable-object (g stream :type t :identity t)
    (format stream "~A state=~A cap=~A"
            (gateway-id g) (gateway-state g) (gateway-capability g))))

;; --------------------------------------------- frame helpers ---

(defun %parse-frame (string)
  "Best-effort parse: returns the head symbol/keyword and the original
string. Falls back to a tag of :UNKNOWN if STRING isn't S-expr-shaped."
  (let ((trimmed (string-left-trim " " (or string ""))))
    (cond
      ((zerop (length trimmed)) (values :unknown nil))
      (t
       (let* ((after-paren (if (char= (char trimmed 0) #\() 1 0))
              (rest (subseq trimmed after-paren))
              (space-pos (position #\Space rest))
              (close-pos (position #\) rest))
              (end (or (and space-pos close-pos (min space-pos close-pos))
                       space-pos close-pos (length rest))))
         (let ((tag (string-downcase (subseq rest 0 end))))
           (values (intern (string-upcase tag) :keyword)
                   trimmed)))))))

(defun %make-auth-frame (identity)
  "Build the auth frame appropriate for IDENTITY:
  - AGENT-IDENTITY → (auth-did <DID> <iso-ts> <hex-sig>) per W3C did:key
  - any other value → (auth <bearer-string>)              ; legacy"
  (typecase identity
    (agent-identity (make-did-auth-frame identity))
    (t (format nil "(auth ~A)" identity))))

(defun %make-register-frame (capability)
  (format nil "(register ~A)" capability))

(defun %make-reply-frame (receipt-id body-sexpr)
  (format nil "(reply ~A ~A)" receipt-id body-sexpr))

(defun %make-heartbeat-frame () "(heartbeat)")

(defun %make-disconnect-frame () "(disconnect)")

;; --------------------------------------------- connect ---

(defun gateway-connect! (gateway &key (timeout 5))
  "Open transport, send auth, wait for auth-ok, send register, wait for
register-ok. Returns T on success, signals on failure."
  (sb-thread:with-mutex ((%gateway-lock gateway))
    (transport-open! (gateway-transport gateway))
    (setf (gateway-state gateway) :authenticating)
    ;; Auth.
    (transport-send! (gateway-transport gateway)
                     (%make-auth-frame (gateway-identity gateway)))
    (let ((reply (transport-recv! (gateway-transport gateway) :timeout timeout)))
      (multiple-value-bind (tag _) (%parse-frame reply)
        (declare (ignore _))
        (unless (eq tag :auth-ok)
          (setf (gateway-state gateway) :failed)
          (error "auth failed: got ~S" reply))))
    (setf (gateway-session gateway) :authenticated)
    ;; Register capability.
    (transport-send! (gateway-transport gateway)
                     (%make-register-frame (gateway-capability gateway)))
    (let ((reply (transport-recv! (gateway-transport gateway) :timeout timeout)))
      (multiple-value-bind (tag _) (%parse-frame reply)
        (declare (ignore _))
        (unless (eq tag :register-ok)
          (setf (gateway-state gateway) :failed)
          (error "register failed: got ~S" reply))))
    (setf (gateway-state gateway) :ready)
    t))

;; --------------------------------------------- threads ---

(defun gateway-start-pumps! (gateway)
  "Spawn the receive-pump and heartbeat threads. Idempotent — only spawns
once per gateway lifetime."
  (sb-thread:with-mutex ((%gateway-lock gateway))
    (unless (%gateway-recv-thread gateway)
      (setf (%gateway-recv-thread gateway)
            (sb-thread:make-thread
             (lambda () (%run-recv-pump gateway))
             :name (format nil "gateway-recv-~A" (gateway-id gateway)))))
    (unless (%gateway-heartbeat-thread gateway)
      (setf (%gateway-heartbeat-thread gateway)
            (sb-thread:make-thread
             (lambda () (%run-heartbeat gateway))
             :name (format nil "gateway-heartbeat-~A" (gateway-id gateway)))))))

(defun %run-recv-pump (gateway)
  "Read frames; route :ask to agent mailbox, log others, ignore :pong."
  (loop until (%gateway-stop-flag gateway)
        for raw = (transport-recv! (gateway-transport gateway) :timeout 1)
        do (cond
             ((eq raw :timeout))
             ((eq raw :closed) (return))
             ((null raw) (return))
             (t
              (multiple-value-bind (tag full) (%parse-frame raw)
                (case tag
                  (:ask
                   (when (gateway-agent gateway)
                     (handler-case
                         (send! (agent-mailbox (gateway-agent gateway))
                                (make-ask full :reply-to (gateway-reply-mailbox gateway)
                                          :meta (list :gateway gateway)))
                       (error () nil)))
                   (when (gateway-receipt-log gateway)
                     (handler-case
                         (append-receipt! (gateway-receipt-log gateway)
                                          :receipt-id (or (%extract-receipt-id full)
                                                          "unknown")
                                          :direction :inbound
                                          :body full
                                          :agent-id (gateway-id gateway)
                                          :status :received)
                       (error () nil))))
                  (:pong)                  ; heartbeat reply, ignore
                  (:error
                   (setf (gateway-state gateway) :failed)
                   (return))
                  (:disconnect
                   (return)))))))
  (setf (gateway-state gateway) :draining))

(defmethod send! ((gw gateway) message)
  "Treat the gateway as an agent's reply mailbox: forward the reply to the
router via the transport. The receipt-id is preserved if the message has
:meta (:receipt-id ...); otherwise we tag with \"rcpt\"."
  (let* ((text (or (and (listp message) (getf message :text)) ""))
         (rid  (or (and (listp message)
                        (let ((meta (getf message :meta)))
                          (and (listp meta) (getf meta :receipt-id))))
                   "rcpt")))
    (handler-case
        (transport-send! (gateway-transport gw)
                         (%make-reply-frame rid text))
      (error () nil))
    (when (gateway-receipt-log gw)
      (handler-case
          (append-receipt! (gateway-receipt-log gw)
                           :receipt-id rid
                           :direction :outbound
                           :body text
                           :agent-id (gateway-id gw)
                           :status :sent)
        (error () nil)))
    message))

(defun gateway-reply-mailbox (gateway)
  "Return the gateway as a reply-mailbox-like target. Agents place this
into ASK :REPLY-TO so SEND! dispatches to the gateway's method, which
forwards the reply onto the wire."
  gateway)

(defun %extract-receipt-id (frame)
  "(ask R-ID body) → R-ID string. Tolerates whitespace; falls back to NIL."
  (let* ((s (string-left-trim " (" frame))
         (after-tag (subseq s (or (position #\Space s) 0)))
         (after-tag-trimmed (string-left-trim " " after-tag))
         (end (or (position #\Space after-tag-trimmed) (length after-tag-trimmed))))
    (and (plusp (length after-tag-trimmed))
         (subseq after-tag-trimmed 0 end))))

(defun %run-heartbeat (gateway)
  (loop until (%gateway-stop-flag gateway)
        do (sleep (gateway-heartbeat-interval gateway))
           (when (eq (gateway-state gateway) :ready)
             (handler-case
                 (transport-send! (gateway-transport gateway)
                                  (%make-heartbeat-frame))
               (error () nil)))))

;; --------------------------------------------- disconnect ---

(defun gateway-disconnect! (gateway)
  "Send disconnect, stop pumps, close transport."
  (setf (%gateway-stop-flag gateway) t)
  (handler-case (transport-send! (gateway-transport gateway)
                                  (%make-disconnect-frame))
    (error () nil))
  (transport-close! (gateway-transport gateway))
  (let ((thr (%gateway-recv-thread gateway)))
    (when (and thr (sb-thread:thread-alive-p thr)
               (not (eq sb-thread:*current-thread* thr)))
      (handler-case (sb-thread:join-thread thr :timeout 2 :default :timeout)
        (error () nil))))
  (setf (gateway-state gateway) :disconnected))

