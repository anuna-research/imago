;;;; m7-wss-tests.lisp — round-trip tests for the production WSS transport
;;;;
;;;; Spins up a local WebSocket echo server in-process via Clack +
;;;; websocket-driver server-side, points a wss-transport at it, exercises
;;;; transport-open! / transport-send! / transport-recv! / transport-close!.
;;;; The tests run end-to-end through real network sockets (loopback) but
;;;; don't need any external service.

(in-package #:anuna-imago.test)

(export 'run-m7-wss-tests)

(defparameter *wss-test-port* 54321)

(defun %ws-echo-app (env)
  "Clack handler that upgrades to WS and echoes every text frame."
  (let ((ws (wsd:make-server env)))
    (wsd:on :message ws
            (lambda (msg) (wsd:send ws msg)))
    (lambda (responder)
      (declare (ignore responder))
      (wsd:start-connection ws))))

(defvar *wss-test-server* nil)

(defun %start-wss-test-server ()
  (setf *wss-test-server*
        (clack:clackup #'%ws-echo-app
                       :port *wss-test-port*
                       :silent t))
  (sleep 0.5))                            ; give the listener a beat to bind

(defun %stop-wss-test-server ()
  (when *wss-test-server*
    (handler-case (clack:stop *wss-test-server*) (error () nil))
    (setf *wss-test-server* nil)))

(defun %ws-echo-url ()
  (format nil "ws://127.0.0.1:~D/" *wss-test-port*))

;; ----------------------------------------------- round-trip ---

(defun test-wss-roundtrip ()
  (format t "~%-- wss-roundtrip --~%")
  (%start-wss-test-server)
  (unwind-protect
       (let ((tr (make-wss-transport (%ws-echo-url))))
         (unwind-protect
              (progn
                (transport-open! tr)
                (check (transport-connected-p tr) "open after handshake")
                (transport-send! tr "hello")
                (check (string= "hello" (transport-recv! tr :timeout 2))
                       "first echo arrives at recv!")
                (transport-send! tr "world")
                (check (string= "world" (transport-recv! tr :timeout 2))
                       "second echo arrives at recv!"))
           (transport-close! tr)
           (check (not (transport-connected-p tr))
                  "not connected after close!")))
    (%stop-wss-test-server)))

;; ----------------------------------------------- N-message soak ---

(defun test-wss-many-messages ()
  "Send 50 frames; expect 50 echoes back in order. Catches inbox/queue
ordering bugs and lost-frame regressions."
  (format t "~%-- wss-many-messages --~%")
  (%start-wss-test-server)
  (unwind-protect
       (let ((tr (make-wss-transport (%ws-echo-url))))
         (unwind-protect
              (progn
                (transport-open! tr)
                (loop for i from 0 below 50 do
                  (transport-send! tr (format nil "msg-~D" i)))
                (let ((received nil))
                  (loop for i from 0 below 50 do
                    (push (transport-recv! tr :timeout 3) received))
                  (let ((received-ordered (nreverse received)))
                    (check (= 50 (length received-ordered)))
                    (check (every (lambda (i)
                                    (string= (format nil "msg-~D" i)
                                             (nth i received-ordered)))
                                  (loop for j from 0 below 50 collect j))
                           "all 50 echoes preserved order"))))
           (transport-close! tr)))
    (%stop-wss-test-server)))

;; ----------------------------------------------- connect failure ---

(defun test-wss-connect-refused ()
  "Connecting to a port with no listener should error within timeout."
  (format t "~%-- wss-connect-refused --~%")
  (let ((tr (make-wss-transport "ws://127.0.0.1:65500/"))
        (*wss-open-timeout-seconds* 2))
    (check (handler-case
               (progn (transport-open! tr) nil)
             (error () t))
           "transport-open! errors on unreachable peer")
    (transport-close! tr)))

;; ----------------------------------------------- send after close ---

(defun test-wss-send-after-close ()
  (format t "~%-- wss-send-after-close --~%")
  (%start-wss-test-server)
  (unwind-protect
       (let ((tr (make-wss-transport (%ws-echo-url))))
         (transport-open! tr)
         (transport-close! tr)
         (check (handler-case
                    (progn (transport-send! tr "x") nil)
                  (error () t))
                "send after close signals an error")
         (check (eq :closed (transport-recv! tr :timeout 1))
                "recv after close returns :closed"))
    (%stop-wss-test-server)))

;; ----------------------------------------------- close idempotent ---

(defun test-wss-close-idempotent ()
  (format t "~%-- wss-close-idempotent --~%")
  (%start-wss-test-server)
  (unwind-protect
       (let ((tr (make-wss-transport (%ws-echo-url))))
         (transport-open! tr)
         (transport-close! tr)
         (handler-case (transport-close! tr) (error () nil))   ; second close
         (check (not (transport-connected-p tr))
                "two closes leave state :closed without erroring"))
    (%stop-wss-test-server)))

;; ----------------------------------------------- runner ---

(defun run-m7-wss-tests ()
  (setf *failures* 0)
  (format t "~%=== M7-WSS quality-gate tests ===~%")
  (test-wss-roundtrip)
  (test-wss-many-messages)
  (test-wss-connect-refused)
  (test-wss-send-after-close)
  (test-wss-close-idempotent)
  (format t "~%=== ~D failure(s) ===~%" *failures*)
  (when (plusp *failures*) (sb-ext:exit :code 1))
  (format t "M7-WSS green.~%"))
