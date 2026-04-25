;;;; producer-gateway.lisp — CBCL Router Producer Client
;;;;
;;;; Mirror of GATEWAY (src/gateway.lisp) for the producer side of the
;;;; CBCL router protocol. Where GATEWAY lets an agent serve asks
;;;; addressed to its registered capability, PRODUCER-GATEWAY lets an
;;;; agent (or any in-process actor) issue asks via the router and
;;;; receive matching replies.
;;;;
;;;; Wire format additions on top of gateway.lisp's vocabulary:
;;;;   Outbound: (produce <receipt-id> <capability> <body>)
;;;;   Inbound:  (reply <receipt-id> <body>)
;;;;             (reject <receipt-id> <reason>)   ; capability not found
;;;;
;;;; Routing happens by receipt-id: the producer maintains an in-flight
;;;; hash mapping receipt-id → reply-mailbox; the recv pump pops the
;;;; entry on (reply …) and feeds the body to the waiting caller.
;;;;
;;;; Same transport abstraction as GATEWAY — production uses
;;;; WSS-TRANSPORT, tests use MOCK-TRANSPORT plus a small fake-router
;;;; thread (see test/m7-producer-tests.lisp).

(in-package #:anuna-imago)

(defclass producer-gateway ()
  ((id              :initarg :id              :reader producer-gateway-id)
   (transport       :initarg :transport       :reader producer-gateway-transport)
   (identity        :initarg :identity        :reader producer-gateway-identity)
   (state           :initform :disconnected   :accessor producer-state)
   (lock            :initform (sb-thread:make-mutex :name "producer-gw") :reader %p-lock)
   (in-flight       :initform (make-hash-table :test 'equal) :reader %p-in-flight
                    :documentation "Map: receipt-id (string) → reply-mailbox.")
   (recv-thread     :initform nil :accessor %p-recv-thread)
   (heartbeat-thread :initform nil :accessor %p-heartbeat-thread)
   (stop-flag       :initform nil :accessor %p-stop-flag)
   (heartbeat-interval :initarg :heartbeat-interval :initform 30
                       :reader producer-heartbeat-interval)))

(defun make-producer-gateway (&key id transport identity (heartbeat-interval 30))
  (make-instance 'producer-gateway
                 :id id :transport transport :identity identity
                 :heartbeat-interval heartbeat-interval))

(defmethod print-object ((gw producer-gateway) stream)
  (print-unreadable-object (gw stream :type t :identity t)
    (format stream "~A state=~A in-flight=~D"
            (producer-gateway-id gw)
            (producer-state gw)
            (hash-table-count (%p-in-flight gw)))))

;; ---------------------------------------------------- frame builder ---

(defun %make-produce-frame (receipt-id capability body)
  (format nil "(produce ~A ~A ~A)" receipt-id capability body))

(defun %generate-receipt-id ()
  "Random 32-hex-char receipt id. Not cryptographically strong; the
router treats receipt-ids as opaque, so collision-resistance via
randomness is sufficient."
  (with-output-to-string (s)
    (loop repeat 16 do (format s "~(~2,'0x~)" (random 256)))))

;; ---------------------------------------------------- connect ---

(defun producer-connect! (gw &key (timeout 5))
  "Open the transport and authenticate. Errors if the router doesn't
return (auth-ok …) within TIMEOUT seconds."
  (sb-thread:with-mutex ((%p-lock gw))
    (transport-open! (producer-gateway-transport gw))
    (setf (producer-state gw) :authenticating)
    (transport-send! (producer-gateway-transport gw)
                     (%make-auth-frame (producer-gateway-identity gw)))
    (let ((reply (transport-recv! (producer-gateway-transport gw)
                                   :timeout timeout)))
      (multiple-value-bind (tag _) (%parse-frame reply)
        (declare (ignore _))
        (unless (eq tag :auth-ok)
          (setf (producer-state gw) :failed)
          (error "producer-gateway auth failed: got ~S" reply))))
    (setf (producer-state gw) :ready)
    t))

;; ---------------------------------------------------- pumps ---

(defun producer-start-pumps! (gw)
  "Spawn the recv pump (routes inbound replies by receipt-id) and the
heartbeat pump (periodic ping). Idempotent."
  (sb-thread:with-mutex ((%p-lock gw))
    (unless (%p-recv-thread gw)
      (setf (%p-recv-thread gw)
            (sb-thread:make-thread
             (lambda () (%run-producer-recv-pump gw))
             :name (format nil "producer-recv-~A" (producer-gateway-id gw)))))
    (unless (%p-heartbeat-thread gw)
      (setf (%p-heartbeat-thread gw)
            (sb-thread:make-thread
             (lambda () (%run-producer-heartbeat gw))
             :name (format nil "producer-heartbeat-~A"
                            (producer-gateway-id gw)))))))

(defun %p-route-reply (gw rid payload)
  "Look up RID in the in-flight table, send PAYLOAD to its mailbox, and
remove the entry. Caller is the recv-pump thread."
  (let ((mb (sb-thread:with-mutex ((%p-lock gw))
              (let ((m (gethash rid (%p-in-flight gw))))
                (when m (remhash rid (%p-in-flight gw)))
                m))))
    (when mb
      (handler-case (send! mb payload) (error () nil)))))

(defun %run-producer-recv-pump (gw)
  (loop until (%p-stop-flag gw)
        for raw = (transport-recv! (producer-gateway-transport gw) :timeout 1)
        do (cond
             ((eq raw :timeout))
             ((eq raw :closed) (return))
             ((null raw) (return))
             (t
              (multiple-value-bind (tag full) (%parse-frame raw)
                (case tag
                  (:reply
                   (let ((rid (%extract-receipt-id full)))
                     (when rid (%p-route-reply gw rid full))))
                  (:reject
                   (let ((rid (%extract-receipt-id full)))
                     (when rid
                       (%p-route-reply gw rid
                                       (list :error :rejected :raw full)))))
                  (:error
                   (setf (producer-state gw) :failed)
                   (return))
                  (:disconnect (return))
                  (:pong)))))))      ; heartbeat ack — ignore

(defun %run-producer-heartbeat (gw)
  (loop until (%p-stop-flag gw)
        do (sleep (producer-heartbeat-interval gw))
           (when (eq (producer-state gw) :ready)
             (handler-case
                 (transport-send! (producer-gateway-transport gw)
                                  (%make-heartbeat-frame))
               (error () nil)))))

;; ---------------------------------------------------- ask + call ---

(defun producer-ask! (gw capability body)
  "Issue an ask to CAPABILITY via the router. Returns a fresh MAILBOX
that the caller should RECEIVE! the reply on. The reply will be the
full inbound frame string (e.g. \"(reply <rid> <body>)\") OR a plist
\(:error :rejected :raw FRAME) if the router returned a rejection.

Async: PRODUCER-ASK! returns immediately; the reply lands in the mailbox
when (or if) the router routes it back."
  (unless (eq (producer-state gw) :ready)
    (error "producer-ask! on non-ready producer-gateway (state=~S)"
           (producer-state gw)))
  (let ((rid (%generate-receipt-id))
        (mb  (make-mailbox)))
    (sb-thread:with-mutex ((%p-lock gw))
      (setf (gethash rid (%p-in-flight gw)) mb))
    (handler-case
        (transport-send! (producer-gateway-transport gw)
                         (%make-produce-frame rid capability body))
      (error (c)
        (sb-thread:with-mutex ((%p-lock gw))
          (remhash rid (%p-in-flight gw)))
        (error c)))
    (values mb rid)))

(defun producer-call! (gw capability body &key (timeout 30))
  "Synchronous wrapper around PRODUCER-ASK!: send and block until a reply
arrives or TIMEOUT seconds pass. Returns the reply payload, :TIMEOUT,
or a plist (:error :rejected …)."
  (multiple-value-bind (mb rid) (producer-ask! gw capability body)
    (declare (ignore rid))
    (receive! mb :timeout timeout)))

;; ---------------------------------------------------- disconnect ---

(defun producer-disconnect! (gw)
  "Send disconnect, stop pumps, close transport. Idempotent."
  (setf (%p-stop-flag gw) t)
  (handler-case (transport-send! (producer-gateway-transport gw)
                                  (%make-disconnect-frame))
    (error () nil))
  (transport-close! (producer-gateway-transport gw))
  (let ((thr (%p-recv-thread gw)))
    (when (and thr (sb-thread:thread-alive-p thr)
               (not (eq sb-thread:*current-thread* thr)))
      (handler-case (sb-thread:join-thread thr :timeout 2 :default :timeout)
        (error () nil))))
  (setf (producer-state gw) :disconnected))

;; ---------------------------------------------------- introspection ---

(defun producer-in-flight-count (gw)
  "Number of asks still awaiting a reply."
  (sb-thread:with-mutex ((%p-lock gw))
    (hash-table-count (%p-in-flight gw))))
