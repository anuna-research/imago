;;;; wss-transport.lisp — WebSocket transport for the gateway
;;;;
;;;; Production-grade companion to MOCK-TRANSPORT in gateway.lisp. Wraps
;;;; websocket-driver-client and bridges its event-driven callbacks
;;;; (:open / :message / :close / :error) onto the gateway's existing
;;;; pull-based TRANSPORT-RECV! API by parking inbound frames into a
;;;; thread-safe MAILBOX.
;;;;
;;;; Connection model:
;;;;   :init  → make-client done, start-connection not yet called
;;;;   :open  → handshake complete; safe to send/recv
;;;;   :closed → peer or local close fired; recv returns :CLOSED
;;;;   :error  → handshake or runtime error; transport unusable
;;;;
;;;; TRANSPORT-OPEN! blocks until one of {:open, :closed, :error} or until
;;;; *WSS-OPEN-TIMEOUT-SECONDS* elapses, then errors if not :open. This
;;;; matches MOCK-TRANSPORT's "errors when not connectable" contract so
;;;; gateway code (gateway-connect!) can handle both transports the same.

(in-package #:anuna-imago)

(defparameter *wss-open-timeout-seconds* 10
  "Maximum time TRANSPORT-OPEN! blocks waiting for the WebSocket :OPEN event.")

(defclass wss-transport ()
  ((url     :initarg :url     :reader wss-transport-url)
   (headers :initarg :headers :initform nil :reader wss-transport-headers
            :documentation "Alist of additional handshake headers, e.g.
                           ((\"authorization\" . \"Bearer …\")).")
   (client  :initform nil :accessor %wss-client)
   (inbox   :initform (make-mailbox) :reader %wss-inbox
            :documentation "Frames that have arrived from the peer.")
   (state   :initform :init :accessor %wss-state)
   (open-cv :initform (sb-thread:make-waitqueue :name "wss-open") :reader %wss-open-cv)
   (lock    :initform (sb-thread:make-mutex :name "wss-state") :reader %wss-lock)))

(defun make-wss-transport (url &key headers)
  "Build a WSS transport. URL is a ws:// or wss:// URL. HEADERS is an
optional alist of extra handshake headers — typical use is bearer auth:
  (make-wss-transport \"wss://router.example/agent/v1\"
                      :headers '((\"authorization\" . \"Bearer …\")))"
  (make-instance 'wss-transport :url url :headers headers))

(defmethod print-object ((tr wss-transport) stream)
  (print-unreadable-object (tr stream :type t :identity t)
    (format stream "~A state=~A inbox=~D"
            (wss-transport-url tr) (%wss-state tr)
            (mailbox-depth (%wss-inbox tr)))))

(defun %set-state! (tr new-state)
  (sb-thread:with-mutex ((%wss-lock tr))
    (setf (%wss-state tr) new-state)
    (sb-thread:condition-broadcast (%wss-open-cv tr))))

(defmethod transport-open! ((tr wss-transport))
  "Initiate the handshake and block until :OPEN, :ERROR, or timeout.
Errors on anything other than :OPEN."
  (let ((client (wsd:make-client (wss-transport-url tr)
                                  :additional-headers
                                  (wss-transport-headers tr))))
    (setf (%wss-client tr) client)
    (wsd:on :open client
            (lambda () (%set-state! tr :open)))
    (wsd:on :message client
            (lambda (msg)
              (handler-case (send! (%wss-inbox tr) msg)
                (error () nil))))      ; mailbox closed during shutdown — drop frame
    (wsd:on :close client
            (lambda (&key code reason)
              (declare (ignore code reason))
              (%set-state! tr :closed)
              (handler-case (close-mailbox! (%wss-inbox tr))
                (error () nil))))
    (wsd:on :error client
            (lambda (e)
              (declare (ignore e))
              (%set-state! tr :error)))
    (wsd:start-connection client)
    (sb-thread:with-mutex ((%wss-lock tr))
      (loop until (member (%wss-state tr) '(:open :closed :error))
            do (unless (sb-thread:condition-wait
                        (%wss-open-cv tr) (%wss-lock tr)
                        :timeout *wss-open-timeout-seconds*)
                 (return))))
    (unless (eq (%wss-state tr) :open)
      (error "wss-transport: handshake failed within ~A s (state=~S, url=~A)"
             *wss-open-timeout-seconds*
             (%wss-state tr)
             (wss-transport-url tr))))
  t)

(defmethod transport-send! ((tr wss-transport) message)
  (unless (eq (%wss-state tr) :open)
    (error "transport-send!: wss-transport not open (state=~S)" (%wss-state tr)))
  (wsd:send (%wss-client tr) message))

(defmethod transport-recv! ((tr wss-transport) &key timeout)
  (cond
    ((eq (%wss-state tr) :closed) :closed)
    (t (receive! (%wss-inbox tr) :timeout timeout))))

(defmethod transport-close! ((tr wss-transport))
  "Close the connection. Idempotent — safe to call multiple times."
  (when (%wss-client tr)
    (handler-case (wsd:close-connection (%wss-client tr))
      (error () nil)))
  (%set-state! tr :closed)
  (handler-case (close-mailbox! (%wss-inbox tr))
    (error () nil)))

(defmethod transport-connected-p ((tr wss-transport))
  (eq (%wss-state tr) :open))
