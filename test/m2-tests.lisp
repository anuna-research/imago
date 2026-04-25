;;;; m2-tests.lisp — quality-gate tests for M2 (hook system)
;;;;
;;;; Run with the same SBCL invocation as M1 but loading
;;;; (anuna-imago.test:run-m2-tests) instead.

(in-package #:anuna-imago.test)

(export 'run-m2-tests)

;; ----------------------------------------------------- sync hooks ---

(defun test-hook-ordering ()
  (format t "~%-- hook-ordering --~%")
  (clear-all-hooks)
  (let ((calls nil))
    (register-hook :on-user-input
                   (lambda (a v) (declare (ignore a))
                     (push 'first calls) v))
    (register-hook :on-user-input
                   (lambda (a v) (declare (ignore a))
                     (push 'second calls) v))
    (register-hook :on-user-input
                   (lambda (a v) (declare (ignore a))
                     (push 'third calls) v))
    (run-hook :on-user-input nil "msg")
    (check (equal '(first second third) (reverse calls))
           "handlers run in registration order")))

(defun test-hook-veto-aborts ()
  (format t "~%-- hook-veto-aborts --~%")
  (clear-all-hooks)
  (let ((calls 0))
    (register-hook :on-tool-call
                   (lambda (a v) (declare (ignore a)) (incf calls) v))
    (register-hook :on-tool-call
                   (lambda (a v) (declare (ignore a v)) (incf calls) :veto))
    (register-hook :on-tool-call
                   (lambda (a v) (declare (ignore a)) (incf calls) v))
    (let ((result (run-hook :on-tool-call nil :call-obj)))
      (check (eq :veto result) ":veto returned to caller")
      (check (= 2 calls) "third handler not called after veto"))))

(defun test-hook-chain-transform ()
  (format t "~%-- hook-chain-transform --~%")
  (clear-all-hooks)
  (register-hook :on-user-input
                 (lambda (a v) (declare (ignore a)) (concatenate 'string v "-A")))
  (register-hook :on-user-input
                 (lambda (a v) (declare (ignore a)) (concatenate 'string v "-B")))
  (register-hook :on-user-input
                 (lambda (a v) (declare (ignore a)) (concatenate 'string v "-C")))
  (let ((result (run-hook :on-user-input nil "start")))
    (check (string= "start-A-B-C" result)
           "value threaded through chain in order")))

(defun test-hook-no-handlers-passes-through ()
  (format t "~%-- hook-no-handlers-passes-through --~%")
  (clear-all-hooks)
  (let ((result (run-hook :on-user-input nil "untouched")))
    (check (string= "untouched" result)
           "with no handlers, primary value is returned unchanged")))

(defun test-hook-remove ()
  (format t "~%-- hook-remove --~%")
  (clear-all-hooks)
  (let* ((calls 0)
         (h (register-hook :on-user-input
                           (lambda (a v) (declare (ignore a)) (incf calls) v))))
    (run-hook :on-user-input nil "x")
    (check (= 1 calls) "before remove: handler runs")
    (check (eq t (remove-hook h)) "remove-hook returns T on success")
    (run-hook :on-user-input nil "x")
    (check (= 1 calls) "after remove: handler does not run")
    (check (null (remove-hook h)) "remove-hook returns NIL when not found")))

;; ----------------------------------------------------- stance enforcement ---

(defun test-hook-excluded-keys-error ()
  (format t "~%-- hook-excluded-keys-error --~%")
  (clear-all-hooks)
  (check (handler-case
             (progn (register-hook :on-prompt-build (lambda (a v) v))
                    nil)
           (error () t))
         ":on-prompt-build registration errors (stance enforcement)")
  (check (handler-case
             (progn (register-hook :on-stream-token (lambda (a v) v))
                    nil)
           (error () t))
         ":on-stream-token registration errors (stance enforcement)"))

(defun test-hook-unknown-key-error ()
  (format t "~%-- hook-unknown-key-error --~%")
  (clear-all-hooks)
  (check (handler-case
             (progn (register-hook :nonsense (lambda (a v) v))
                    nil)
           (error () t))
         "unknown hook key registration errors"))

;; ---------------------------------------------- fire-and-forget timing ---

(defun test-hook-fire-and-forget-non-blocking ()
  (format t "~%-- hook-fire-and-forget-non-blocking --~%")
  (clear-all-hooks)
  (let ((slow-finished nil))
    (register-hook :on-turn-complete
                   (lambda (a) (declare (ignore a))
                     (sleep 0.5)
                     (setf slow-finished t)))
    (let ((start (get-internal-real-time)))
      (run-hook :on-turn-complete nil)
      (let ((elapsed-ms (* 1000 (/ (- (get-internal-real-time) start)
                                   internal-time-units-per-second))))
        (check (< elapsed-ms 100)
               "run-hook returns within 100ms despite 500ms handler")))
    (sleep 0.7)
    (check slow-finished "fire-and-forget handler did eventually run")
    (shutdown-hook-async-pool)))

;; ---------------------------------------------------------------- runner ---

(defun run-m2-tests ()
  (setf *failures* 0)
  (format t "~%=== M2 quality-gate tests ===~%")
  (test-hook-ordering)
  (test-hook-veto-aborts)
  (test-hook-chain-transform)
  (test-hook-no-handlers-passes-through)
  (test-hook-remove)
  (test-hook-excluded-keys-error)
  (test-hook-unknown-key-error)
  (test-hook-fire-and-forget-non-blocking)
  (format t "~%=== ~D failure(s) ===~%" *failures*)
  (when (plusp *failures*) (sb-ext:exit :code 1))
  (format t "M2 green.~%"))
