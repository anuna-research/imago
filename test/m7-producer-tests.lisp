;;;; m7-producer-tests.lisp — quality-gate tests for producer-gateway
;;;;
;;;; Uses MOCK-TRANSPORT plus a small fake-router thread that auths
;;;; producers and echoes (produce …) frames as (reply …) frames.

(in-package #:anuna-imago.test)

(export 'run-m7-producer-tests)

(defun %extract-produce-rid (frame)
  "Pull the receipt-id out of a `(produce <rid> <cap> <body>)` frame."
  (let* ((s (string-left-trim " (" frame))
         (after-tag (string-left-trim " " (subseq s (or (position #\Space s) 0))))
         (end (or (position #\Space after-tag) (length after-tag))))
    (and (plusp (length after-tag)) (subseq after-tag 0 end))))

(defun %extract-produce-cap (frame)
  (let* ((after-tag-rid
           (string-left-trim " "
                              (subseq frame
                                       (or (position #\Space frame) 0))))
         (after-rid
           (string-left-trim " "
                              (subseq after-tag-rid
                                       (or (position #\Space after-tag-rid) 0))))
         (end (or (position #\Space after-rid) (length after-rid))))
    (subseq after-rid 0 end)))

(defun %fake-producer-router (transport &key reject-cap)
  "Background thread that pretends to be a CBCL router for producer
testing. Auths immediately; on each `(produce …)` frame, echoes a
`(reply …)` frame matching the receipt-id, unless the capability is
REJECT-CAP, in which case it sends `(reject …)`."
  (sb-thread:make-thread
   (lambda ()
     (loop
       (let ((frame (mock-drain! transport :timeout 5)))
         (cond
           ((eq frame :timeout) (return))
           ((null frame) (return))
           ((search "(auth" frame)
            (mock-feed! transport "(auth-ok producer-1)"))
           ((search "(produce" frame)
            (let ((rid (%extract-produce-rid frame))
                  (cap (%extract-produce-cap frame)))
              (cond
                ((and reject-cap (string= cap reject-cap))
                 (mock-feed! transport
                             (format nil "(reject ~A no-such-capability)" rid)))
                (t
                 (mock-feed! transport
                             (format nil "(reply ~A done-~A)" rid cap))))))
           ((search "(heartbeat" frame)
            (mock-feed! transport "(pong)"))
           ((search "(disconnect" frame) (return))
           (t nil)))))
   :name "fake-producer-router"))

;; ----------------------------------------------- connect ---

(defun test-producer-connect ()
  (format t "~%-- producer-connect --~%")
  (let* ((tr (make-mock-transport))
         (gw (make-producer-gateway :id 'p-1 :transport tr
                                     :identity "agent-token"
                                     :heartbeat-interval 30))
         (router (%fake-producer-router tr)))
    (producer-connect! gw :timeout 2)
    (check (eq :ready (producer-state gw)) "state reaches :ready after auth")
    (producer-disconnect! gw)
    (check (eq :disconnected (producer-state gw)))
    (handler-case (sb-thread:join-thread router :timeout 2) (error () nil))))

;; ----------------------------------------------- ask + call ---

(defun test-producer-call-roundtrip ()
  (format t "~%-- producer-call-roundtrip --~%")
  (let* ((tr (make-mock-transport))
         (gw (make-producer-gateway :id 'p-2 :transport tr
                                     :identity "agent-token"
                                     :heartbeat-interval 30))
         (router (%fake-producer-router tr)))
    (producer-connect! gw :timeout 2)
    (producer-start-pumps! gw)
    (let ((reply (producer-call! gw "echo:say" "hello" :timeout 3)))
      (check (and (stringp reply) (search "done-echo:say" reply))
             "reply payload arrives via receipt-id routing"))
    (producer-disconnect! gw)
    (handler-case (sb-thread:join-thread router :timeout 2) (error () nil))))

;; ----------------------------------------------- multiple in-flight ---

(defun test-producer-many-in-flight ()
  "Send 5 asks, expect 5 replies routed to the right caller. Catches
in-flight registry / receipt-id matching bugs."
  (format t "~%-- producer-many-in-flight --~%")
  (let* ((tr (make-mock-transport))
         (gw (make-producer-gateway :id 'p-3 :transport tr
                                     :identity "agent-token"
                                     :heartbeat-interval 30))
         (router (%fake-producer-router tr)))
    (producer-connect! gw :timeout 2)
    (producer-start-pumps! gw)
    (let ((mailboxes
            (loop for i from 0 below 5
                  collect (multiple-value-bind (mb _)
                              (producer-ask! gw
                                              (format nil "cap-~D" i)
                                              "body")
                            (declare (ignore _))
                            mb))))
      (let ((replies (mapcar (lambda (mb) (receive! mb :timeout 3)) mailboxes)))
        (check (= 5 (length replies)))
        (check (every #'stringp replies))
        (check (loop for i from 0 below 5
                     for r in replies
                     always (search (format nil "done-cap-~D" i) r))
               "each reply routes to the mailbox for its specific cap")))
    (check (zerop (producer-in-flight-count gw))
           "in-flight registry drained after all replies routed")
    (producer-disconnect! gw)
    (handler-case (sb-thread:join-thread router :timeout 2) (error () nil))))

;; ----------------------------------------------- rejection ---

(defun test-producer-call-rejected ()
  (format t "~%-- producer-call-rejected --~%")
  (let* ((tr (make-mock-transport))
         (gw (make-producer-gateway :id 'p-4 :transport tr
                                     :identity "agent-token"
                                     :heartbeat-interval 30))
         (router (%fake-producer-router tr :reject-cap "missing:cap")))
    (producer-connect! gw :timeout 2)
    (producer-start-pumps! gw)
    (let ((reply (producer-call! gw "missing:cap" "body" :timeout 3)))
      (check (and (listp reply) (eq :rejected (getf reply :error)))
             "rejection from router surfaces as :error :rejected"))
    (producer-disconnect! gw)
    (handler-case (sb-thread:join-thread router :timeout 2) (error () nil))))

;; ----------------------------------------------- timeout ---

(defun test-producer-call-timeout ()
  "If the router never replies, PRODUCER-CALL! returns :TIMEOUT."
  (format t "~%-- producer-call-timeout --~%")
  (let* ((tr (make-mock-transport))
         (gw (make-producer-gateway :id 'p-5 :transport tr
                                     :identity "agent-token"
                                     :heartbeat-interval 30))
         (silent-router
           (sb-thread:make-thread
            (lambda ()
              (let ((frame (mock-drain! tr :timeout 2)))
                (when (and frame (search "(auth" frame))
                  (mock-feed! tr "(auth-ok session)"))
                ;; Eat further frames silently — never reply.
                (loop for f = (mock-drain! tr :timeout 2)
                      while (and f (not (eq f :timeout)))
                      finally (return))))
            :name "silent-router")))
    (producer-connect! gw :timeout 2)
    (producer-start-pumps! gw)
    (let ((reply (producer-call! gw "blackhole:cap" "body" :timeout 1)))
      (check (eq :timeout reply) "no reply within budget → :timeout"))
    (producer-disconnect! gw)
    (handler-case (sb-thread:join-thread silent-router :timeout 3) (error () nil))))

;; ----------------------------------------------- runner ---

(defun run-m7-producer-tests ()
  (setf *failures* 0)
  (format t "~%=== M7-Producer quality-gate tests ===~%")
  (test-producer-connect)
  (test-producer-call-roundtrip)
  (test-producer-many-in-flight)
  (test-producer-call-rejected)
  (test-producer-call-timeout)
  (format t "~%=== ~D failure(s) ===~%" *failures*)
  (when (plusp *failures*) (sb-ext:exit :code 1))
  (format t "M7-Producer green.~%"))
