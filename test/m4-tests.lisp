;;;; m4-tests.lisp — quality-gate tests for M4 (turn-loop + stub provider + echo)

(in-package #:anuna-imago.test)

(export 'run-m4-tests)

;; ----------------------------------------------- single ask round-trip ---

(defun test-echo-single-ask ()
  (format t "~%-- echo-single-ask --~%")
  (clear-all-hooks) (clear-all-tools)
  (let* ((sup   (make-supervisor 'echo-sup-1 :max-restarts 3))
         (agent (build-echo-agent)))
    (spawn-agent! sup agent)
    (sleep 0.05)
    (let ((reply (ask-agent agent "hello")))
      (check (eq :reply (getf reply :type)))
      (check (string= "echo: hello" (getf reply :text))))
    (send! (agent-mailbox agent) :shutdown)
    (sleep 0.05)
    (drain-supervisor! sup)))

;; ----------------------------------------------- 100-ask soak ---

(defun test-echo-100-asks ()
  "Phase-1 quality gate: agent serves 100 asks against stub provider with
no errors, no leaks."
  (format t "~%-- echo-100-asks --~%")
  (clear-all-hooks) (clear-all-tools)
  (let* ((sup   (make-supervisor 'echo-sup-100 :max-restarts 3))
         (agent (build-echo-agent)))
    (spawn-agent! sup agent)
    (sleep 0.05)
    (let ((failures 0))
      (loop for i from 0 below 100
            do (let ((reply (ask-agent agent (format nil "msg-~D" i)
                                       :timeout 2)))
                 (unless (and (listp reply)
                              (string= (format nil "echo: msg-~D" i)
                                       (getf reply :text)))
                   (incf failures))))
      (check (zerop failures)
             (format nil "100 asks: ~D failures" failures)))
    (check (eq :running (sup-state sup))
           "supervisor still :running after 100 asks (no crashes)")
    (send! (agent-mailbox agent) :shutdown)
    (sleep 0.05)
    (drain-supervisor! sup)))

;; ----------------------------------------------- hook integration ---

(defun test-on-user-input-hook ()
  (format t "~%-- on-user-input-hook --~%")
  (clear-all-hooks) (clear-all-tools)
  (let* ((sup   (make-supervisor 'echo-sup-hook :max-restarts 3))
         (agent (build-echo-agent)))
    ;; Rewrite content to upper case before the provider sees it.
    (register-hook :on-user-input
                   (lambda (a msg)
                     (declare (ignore a))
                     (let ((upper (string-upcase (or (ask-content msg) ""))))
                       (list :type :ask :content upper
                             :reply-to (ask-reply-to msg)))))
    (spawn-agent! sup agent)
    (sleep 0.05)
    (let ((reply (ask-agent agent "shouty")))
      (check (string= "echo: SHOUTY" (getf reply :text))
             "input hook transforms content"))
    (send! (agent-mailbox agent) :shutdown)
    (sleep 0.05)
    (drain-supervisor! sup)))

(defun test-on-turn-complete-fires ()
  (format t "~%-- on-turn-complete-fires --~%")
  (clear-all-hooks) (clear-all-tools)
  (let* ((sup     (make-supervisor 'echo-sup-tc :max-restarts 3))
         (agent   (build-echo-agent))
         (counter 0)
         (lock    (sb-thread:make-mutex)))
    (register-hook :on-turn-complete
                   (lambda (a) (declare (ignore a))
                     (sb-thread:with-mutex (lock) (incf counter))))
    (spawn-agent! sup agent)
    (sleep 0.05)
    (ask-agent agent "a")
    (ask-agent agent "b")
    (ask-agent agent "c")
    (sleep 0.3)                              ; let async hooks land
    (check (= 3 counter) ":on-turn-complete fired once per turn")
    (send! (agent-mailbox agent) :shutdown)
    (sleep 0.05)
    (drain-supervisor! sup)
    (shutdown-hook-async-pool)))

;; ----------------------------------------------- tool dispatch ---

(defun make-tool-stub-provider ()
  "Stub that emits a tool-use frame followed by a text frame after the tool
result would have been incorporated."
  (make-stub-provider
   :responder (lambda (msg)
                (declare (ignore msg))
                (list (list :tool-use "call-1" 'add (list :a 2 :b 3))
                      (list :text "computed")))))

(defun test-tool-call-dispatch ()
  (format t "~%-- tool-call-dispatch --~%")
  (clear-all-hooks) (clear-all-tools)
  (define-tool add
    :description "Add two numbers"
    :schema ((:a :type :integer :required-p t) (:b :type :integer :required-p t))
    :handler (lambda (args) (+ (getf args :a) (getf args :b))))
  (let* ((sup   (make-supervisor 'tool-sup :max-restarts 3))
         (agent (make-instance 'agent
                               :id 'tool-agent
                               :capability "math:add"
                               :provider (make-tool-stub-provider))))
    (spawn-agent! sup agent)
    (sleep 0.05)
    (let* ((reply (ask-agent agent "compute"))
           (results (getf reply :tool-results)))
      (check (= 1 (length results)))
      (let ((r (first results)))
        (check (eq :ok (getf r :status)))
        (check (= 5 (getf r :value)) "add(2,3) = 5"))
      (check (string= "computed" (getf reply :text))))
    (send! (agent-mailbox agent) :shutdown)
    (sleep 0.05)
    (drain-supervisor! sup)))

(defun test-tool-veto ()
  (format t "~%-- tool-veto --~%")
  (clear-all-hooks) (clear-all-tools)
  (define-tool dangerous
    :schema ()
    :handler (lambda (a) (declare (ignore a))
               (error "should not be called")))
  (register-hook :on-tool-call
                 (lambda (agent call)
                   (declare (ignore agent call))
                   :veto))
  (let* ((sup   (make-supervisor 'veto-sup :max-restarts 3))
         (agent (make-instance 'agent
                               :id 'veto-agent
                               :capability "x"
                               :provider
                               (make-stub-provider
                                :responder
                                (lambda (m) (declare (ignore m))
                                  (list (list :tool-use "id" 'dangerous nil)))))))
    (spawn-agent! sup agent)
    (sleep 0.05)
    (let* ((reply (ask-agent agent "go"))
           (results (getf reply :tool-results)))
      (check (eq :vetoed (getf (first results) :status))
             ":on-tool-call :veto blocks dispatch"))
    (send! (agent-mailbox agent) :shutdown)
    (sleep 0.05)
    (drain-supervisor! sup)))

;; ----------------------------------------------- live redefinition ---

(defun test-process-turn-redefinable ()
  "REQ-004 substrate: redefine PROCESS-TURN mid-flight; next turn uses new def."
  (format t "~%-- process-turn-redefinable --~%")
  (clear-all-hooks) (clear-all-tools)
  (let* ((sup   (make-supervisor 'redef-sup :max-restarts 3))
         (agent (build-echo-agent)))
    (spawn-agent! sup agent)
    (sleep 0.05)
    (let ((reply1 (ask-agent agent "x")))
      (check (string= "echo: x" (getf reply1 :text))))
    ;; Replace PROCESS-TURN to bypass provider entirely, returning a marker reply.
    (let ((original (symbol-function 'anuna-imago::process-turn)))
      (unwind-protect
           (progn
             (setf (symbol-function 'anuna-imago::process-turn)
                   (lambda (agent msg)
                     (declare (ignore agent))
                     (let ((reply (make-reply "REDEF")))
                       (when (ask-reply-to msg)
                         (handler-case (send! (ask-reply-to msg) reply)
                           (error () nil)))
                       reply)))
             (let ((reply2 (ask-agent agent "x")))
               (check (string= "REDEF" (getf reply2 :text))
                      "next dispatch sees redefined PROCESS-TURN")))
        (setf (symbol-function 'anuna-imago::process-turn) original)))
    (send! (agent-mailbox agent) :shutdown)
    (sleep 0.05)
    (drain-supervisor! sup)))

;; ----------------------------------------------- echo demo ---

(defun test-run-echo-demo ()
  (format t "~%-- run-echo-demo --~%")
  (clear-all-hooks) (clear-all-tools)
  (let ((replies (run-echo-demo)))
    (check (equal '("echo: hello" "echo: world" "echo: !") replies))))

;; ---------------------------------------------------------------- runner ---

(defun run-m4-tests ()
  (setf *failures* 0)
  (format t "~%=== M4 quality-gate tests ===~%")
  (test-echo-single-ask)
  (test-echo-100-asks)
  (test-on-user-input-hook)
  (test-on-turn-complete-fires)
  (test-tool-call-dispatch)
  (test-tool-veto)
  (test-process-turn-redefinable)
  (test-run-echo-demo)
  (format t "~%=== ~D failure(s) ===~%" *failures*)
  (when (plusp *failures*) (sb-ext:exit :code 1))
  (format t "M4 green.~%"))
