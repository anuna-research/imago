;;;; m1-tests.lisp — quality-gate tests for M1 (mailbox, supervisor, agent)
;;;;
;;;; Run with:
;;;;   sbcl --non-interactive --no-userinit \
;;;;        --eval '(require :asdf)' \
;;;;        --eval '(push (truename ".") asdf:*central-registry*)' \
;;;;        --eval '(asdf:load-system :imago/test)' \
;;;;        --eval '(anuna-imago.test:run-m1-tests)'

(in-package #:cl-user)

(defpackage #:anuna-imago.test
  (:use #:cl #:anuna-imago)
  (:export #:run-m1-tests))

(in-package #:anuna-imago.test)

(defvar *failures* 0)

(defmacro check (form &optional msg)
  ;; Use a gensym so the macro doesn't shadow caller variables named RESULT.
  (let ((r (gensym "CHECK-")))
    `(handler-case
         (let ((,r ,form))
           (cond (,r (format t "  ok    ~S~@[ — ~A~]~%" ',form ,msg))
                 (t (incf *failures*)
                    (format t "  FAIL  ~S~@[ — ~A~]~%" ',form ,msg))))
       (error (c)
         (incf *failures*)
         (format t "  ERROR ~S — ~A~@[ — ~A~]~%" ',form c ,msg)))))

;; ----------------------------------------------------------- mailbox ---

(defun test-mailbox-roundtrip ()
  (format t "~%-- mailbox-roundtrip --~%")
  (let ((mb (make-mailbox)))
    (check (zerop (mailbox-depth mb)))
    (send! mb :a) (send! mb :b) (send! mb :c)
    (check (= 3 (mailbox-depth mb)))
    (check (eq :a (receive! mb)))
    (check (eq :b (receive! mb)))
    (check (eq :c (receive! mb)))
    (check (zerop (mailbox-depth mb)))))

(defun test-mailbox-timeout ()
  (format t "~%-- mailbox-timeout --~%")
  (let ((mb (make-mailbox)))
    (check (eq :timeout (receive! mb :timeout 0.1)))))

(defun test-mailbox-close ()
  (format t "~%-- mailbox-close --~%")
  (let ((mb (make-mailbox)))
    (send! mb :a)
    (close-mailbox! mb)
    (check (eq :a (receive! mb)) "drains before reporting :closed")
    (check (eq :closed (receive! mb)))))

(defun test-mailbox-blocking-receive-wakes ()
  (format t "~%-- mailbox-blocking-receive-wakes --~%")
  (let* ((mb (make-mailbox))
         (received (cons nil nil))
         (consumer (sb-thread:make-thread
                    (lambda () (setf (car received) (receive! mb)))
                    :name "test-consumer")))
    (sleep 0.05)                       ; let consumer block
    (send! mb :hello)
    (handler-case (sb-thread:join-thread consumer :timeout 2)
      (error () nil))
    (check (eq :hello (car received)))))

;; ---------------------------------------------------------- supervisor ---

(defun test-supervisor-restart-and-escalate ()
  (format t "~%-- supervisor-restart-and-escalate --~%")
  (let* ((sup (make-supervisor 'crashy-sup :max-restarts 3 :within-seconds 60))
         (started 0)
         (count-lock (sb-thread:make-mutex)))
    (add-child! sup 'crashy
                (lambda ()
                  (sb-thread:with-mutex (count-lock) (incf started))
                  (sleep 0.05)
                  (error "boom")))
    (start-supervisor! sup)
    ;; Allow several restart cycles to play out then escalation.
    (loop for i from 0 below 30
          while (eq (sup-state sup) :running)
          do (sleep 0.1))
    (check (eq :failed (sup-state sup)) "escalates to :failed after max-restarts")
    (check (= 3 started) "child started exactly max-restarts times")
    (drain-supervisor! sup)
    (check (eq :stopped (sup-state sup)) "drain reaches :stopped")))

(defun test-supervisor-normal-exit-no-restart ()
  (format t "~%-- supervisor-normal-exit-no-restart --~%")
  (let* ((sup (make-supervisor 'normal-sup :max-restarts 5))
         (calls 0)
         (lock (sb-thread:make-mutex)))
    (add-child! sup 'noop
                (lambda ()
                  (sb-thread:with-mutex (lock) (incf calls))))     ; returns immediately
    (start-supervisor! sup)
    (sleep 0.3)
    (check (= 1 calls) "child does not restart after :normal exit")
    (check (eq :stopped (child-state-of sup 'noop)))
    (drain-supervisor! sup)))

(defun test-supervisor-introspection ()
  (format t "~%-- supervisor-introspection --~%")
  (let ((sup (make-supervisor 'introspect-sup)))
    (add-child! sup 'a (lambda () (sleep 5)))
    (add-child! sup 'b (lambda () (sleep 5)))
    (start-supervisor! sup)
    (sleep 0.1)
    (let ((listing (list-children sup)))
      (check (= 2 (length listing)))
      (check (every (lambda (e) (eq (getf e :state) :running)) listing)
             "all children :running"))
    (drain-supervisor! sup)))

;; ---------------------------------------------------------------- agent ---

(defun test-agent-instantiation ()
  (format t "~%-- agent-instantiation --~%")
  (let ((a (make-instance 'agent
                          :id 'test-a
                          :capability "echo:say"
                          :system-prompt "You are echo.")))
    (check (eq 'test-a (agent-id a)))
    (check (string= "echo:say" (agent-capability a)))
    (check (string= "You are echo." (agent-system-prompt a)))
    (check (eq :initialised (agent-state a)))
    (check (zerop (mailbox-depth (agent-mailbox a))))))

(defun test-agent-handle-message-redefinable ()
  "REQ-004 substrate check: redefining a defmethod takes effect on next dispatch."
  (format t "~%-- agent-handle-message-redefinable --~%")
  (let* ((received (cons nil nil))
         (a (make-instance 'agent :id 'redef-a :capability "x:y")))
    ;; Define a subclass-less :around method temporarily then remove it.
    (defmethod handle-message ((ag agent) msg)
      (setf (car received) msg))
    (handle-message a :first)
    (check (eq :first (car received)))
    ;; Redefine: append to a list instead.
    (defmethod handle-message ((ag agent) msg)
      (push msg (car received)))
    (setf (car received) nil)
    (handle-message a :a) (handle-message a :b) (handle-message a :c)
    (check (equal '(:c :b :a) (car received)) "redefined method takes effect")))

;; ---------------------------------------------------------------- runner ---

(defun run-m1-tests ()
  (setf *failures* 0)
  (format t "~%=== M1 quality-gate tests ===~%")
  (test-mailbox-roundtrip)
  (test-mailbox-timeout)
  (test-mailbox-close)
  (test-mailbox-blocking-receive-wakes)
  (test-supervisor-restart-and-escalate)
  (test-supervisor-normal-exit-no-restart)
  (test-supervisor-introspection)
  (test-agent-instantiation)
  (test-agent-handle-message-redefinable)
  (format t "~%=== ~D failure(s) ===~%" *failures*)
  (when (plusp *failures*) (sb-ext:exit :code 1))
  (format t "M1 green.~%"))
