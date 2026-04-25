;;;; m7-tests.lisp — quality-gate tests for M7 (gateway + mock transport)

(in-package #:anuna-imago.test)

(export 'run-m7-tests)

;; ----------------------------------------------- transport round-trip ---

(defun test-mock-transport-roundtrip ()
  (format t "~%-- mock-transport-roundtrip --~%")
  (let ((tr (make-mock-transport)))
    (transport-open! tr)
    (check (transport-connected-p tr))
    (mock-feed! tr "(ask r1 (greeting hello))")
    (check (string= "(ask r1 (greeting hello))"
                    (transport-recv! tr :timeout 1)))
    (transport-send! tr "(reply r1 hi)")
    (check (string= "(reply r1 hi)" (mock-drain! tr :timeout 1)))
    (transport-close! tr)
    (check (not (transport-connected-p tr)))))

;; ----------------------------------------------- connect / state machine ---

(defun %simulate-router (transport)
  "Background thread that mimics a CBCL router: ack auth, ack register,
ignore heartbeats. Returns the thread so the test can join it."
  (sb-thread:make-thread
   (lambda ()
     (loop
       (let ((frame (mock-drain! transport :timeout 5)))
         (cond
           ((eq frame :timeout) (return))
           ((null frame) (return))
           ((search "(auth" frame)
            (mock-feed! transport "(auth-ok session-1)"))
           ((search "(register" frame)
            (mock-feed! transport "(register-ok cap)"))
           ((search "(heartbeat" frame)
            (mock-feed! transport "(pong)"))
           ((search "(disconnect" frame) (return))
           (t nil)))))
   :name "test-router"))

(defun test-gateway-connect ()
  (format t "~%-- gateway-connect --~%")
  (let* ((tr (make-mock-transport))
         (gw (make-gateway :id 'gw-1 :transport tr
                            :identity "agent-token"
                            :capability "echo:say"
                            :heartbeat-interval 0.1))
         (router-thr (%simulate-router tr)))
    (gateway-connect! gw :timeout 2)
    (check (eq :ready (gateway-state gw)) "state reaches :ready")
    (gateway-disconnect! gw)
    (check (eq :disconnected (gateway-state gw)) "drain reaches :disconnected")
    (handler-case (sb-thread:join-thread router-thr :timeout 2)
      (error () nil))))

;; ----------------------------------------------- inbound ask routes to agent ---

(defun test-gateway-inbound-ask ()
  (format t "~%-- gateway-inbound-ask --~%")
  (let* ((tr (make-mock-transport))
         (agent (make-instance 'agent :id 'a :capability "echo:say"))
         (gw (make-gateway :id 'gw-2 :transport tr
                            :identity "agent-token"
                            :capability "echo:say"
                            :agent agent
                            :heartbeat-interval 30))
         (router-thr (%simulate-router tr)))
    (gateway-connect! gw :timeout 2)
    (gateway-start-pumps! gw)
    (mock-feed! tr "(ask rcpt-9 (do-thing))")
    (sleep 0.2)
    (check (= 1 (mailbox-depth (agent-mailbox agent)))
           "ask landed in agent mailbox")
    (let ((msg (receive! (agent-mailbox agent) :timeout 1)))
      (check (eq :ask (getf msg :type)))
      (check (search "rcpt-9" (or (ask-content msg) ""))
             "ask content carries the receipt id"))
    (gateway-disconnect! gw)
    (handler-case (sb-thread:join-thread router-thr :timeout 2) (error () nil))))

;; ----------------------------------------------- outbound reply ---

(defun test-gateway-outbound-reply ()
  (format t "~%-- gateway-outbound-reply --~%")
  (let* ((tr (make-mock-transport))
         (gw (make-gateway :id 'gw-3 :transport tr
                            :identity "agent-token"
                            :capability "echo:say"
                            :heartbeat-interval 30))
         (router-thr (%simulate-router tr)))
    (gateway-connect! gw :timeout 2)
    ;; Drain auth + register frames out of the way
    (sleep 0.1)
    ;; Now send a reply through the gateway (treating it as a mailbox).
    (send! gw (make-reply "the response"
                          :meta (list :receipt-id "rcpt-X")))
    (let ((wire-frame nil))
      (loop for f = (mock-drain! tr :timeout 1)
            while (and f (not (eq f :timeout)))
            until (search "rcpt-X" (or f ""))
            do (setf wire-frame f)
            finally (when (and f (not (eq f :timeout))) (setf wire-frame f)))
      (check (and wire-frame (search "rcpt-X" wire-frame)
                   (search "the response" wire-frame))
             "outbound reply frame carries receipt-id and body"))
    (gateway-disconnect! gw)
    (handler-case (sb-thread:join-thread router-thr :timeout 2) (error () nil))))

;; ----------------------------------------------- frame parser ---

(defun test-frame-parser ()
  "Internal helper test: %parse-frame should return the head keyword."
  (format t "~%-- gateway-frame-parser --~%")
  (multiple-value-bind (tag _)
      (anuna-imago::%parse-frame "(auth token)")
    (declare (ignore _))
    (check (eq :auth tag)))
  (multiple-value-bind (tag _)
      (anuna-imago::%parse-frame "(ask receipt-1 body)")
    (declare (ignore _))
    (check (eq :ask tag)))
  (multiple-value-bind (tag _)
      (anuna-imago::%parse-frame "(pong)")
    (declare (ignore _))
    (check (eq :pong tag))))

;; ----------------------------------------------- auth failure path ---

(defun test-gateway-auth-failure ()
  (format t "~%-- gateway-auth-failure --~%")
  (let* ((tr (make-mock-transport))
         (gw (make-gateway :id 'gw-fail :transport tr
                            :identity "bad-token"
                            :capability "echo:say"
                            :heartbeat-interval 30))
         ;; A mean router that rejects auth
         (router (sb-thread:make-thread
                  (lambda ()
                    (mock-drain! tr :timeout 2)
                    (mock-feed! tr "(error auth-rejected)"))
                  :name "mean-router")))
    (check (handler-case (progn (gateway-connect! gw :timeout 2) nil)
             (error () t))
           "auth rejection signals an error")
    (transport-close! tr)
    (handler-case (sb-thread:join-thread router :timeout 2) (error () nil))))

;; ---------------------------------------------------------------- runner ---

(defun run-m7-tests ()
  (setf *failures* 0)
  (format t "~%=== M7 quality-gate tests ===~%")
  (test-mock-transport-roundtrip)
  (test-gateway-connect)
  (test-gateway-inbound-ask)
  (test-gateway-outbound-reply)
  (test-frame-parser)
  (test-gateway-auth-failure)
  (format t "~%=== ~D failure(s) ===~%" *failures*)
  (when (plusp *failures*) (sb-ext:exit :code 1))
  (format t "M7 green.~%"))
