;;;; m10-tests.lisp — quality-gate tests for M10 (reasoner + invariant filter)
;;;;
;;;; The reasoner is mocked: tests bind *REASONER-IPC-CALL* to a function
;;;; that returns canned proof-results. A live spindle-rs round-trip is
;;;; out of scope for unit tests but the IPC seam is exercised end-to-end.

(in-package #:anuna-imago.test)

(export 'run-m10-tests)

(defun %ok-positive-result ()
  "Canned proof-result: definitely provable."
  (list :tag :+delta :derivation '(rule-1) :time-ms 1))

(defun %negative-result ()
  (list :tag :-delta :derivation nil :time-ms 1))

;; ----------------------------------------------------- IPC plumbing ---

(defun test-reasoner-ipc-not-configured ()
  (format t "~%-- reasoner-ipc-not-configured --~%")
  (let ((*reasoner-ipc-call*
          (lambda (op &rest args)
            (declare (ignore op args))
            (error "No reasoner configured."))))
    (check (handler-case (progn (query :handle '(forbidden delete-user)) nil)
             (error () t))
           "default IPC errors out")))

(defun test-reasoner-load-theory ()
  (format t "~%-- reasoner-load-theory --~%")
  (let ((calls nil))
    (let ((*reasoner-ipc-call*
            (lambda (op &rest args)
              (push (cons op args) calls)
              :handle-1)))
      (let ((h (load-theory "(rule never-delete (forbidden delete-user))")))
        (check (eq :handle-1 h))
        (check (= 1 (length calls)))
        (check (eq :load-theory (caar calls)))))))

(defun test-reasoner-query ()
  (format t "~%-- reasoner-query --~%")
  (let ((*reasoner-ipc-call*
          (lambda (op &rest args)
            (declare (ignore args))
            (case op
              (:query (%ok-positive-result))
              (t (error "unexpected op ~S" op))))))
    (let ((r (query :handle '(forbidden x))))
      (check (proof-result-positive-p r) "+Δ result is positive")
      (check (eq :+delta (getf r :tag))))))

;; ----------------------------------------------------- invariant filter ---

(defun test-invariant-filter-vetoes-forbidden ()
  "Note: setf-then-restore on *REASONER-IPC-CALL* (not LET) because the
agent runs in a child thread that doesn't see thread-local bindings."
  (format t "~%-- invariant-filter-vetoes-forbidden --~%")
  (clear-all-hooks) (clear-all-tools)
  (define-tool delete-user :schema ()
    :handler (lambda (a) (declare (ignore a)) :deleted))
  (let ((original *reasoner-ipc-call*))
    (unwind-protect
         (progn
           (setf *reasoner-ipc-call*
                 (lambda (op &rest args)
                   (case op
                     (:load-theory :h-1)
                     (:query
                      (let ((goal (second args)))
                        (cond
                          ((and (listp goal) (eq :forbidden (first goal))
                                (eq 'delete-user (second goal)))
                           (%ok-positive-result))
                          (t (%negative-result))))))))
           (let ((handle (load-theory "..."))
                 (sup    (make-supervisor 'inv-sup :max-restarts 3)))
             (install-invariant-filter! :theory-handle handle)
             (unwind-protect
                  (let ((agent (make-instance 'agent :id 'inv-a :capability "x"
                                                      :tools '(delete-user)
                                                      :provider
                                                      (make-stub-provider
                                                       :responder
                                                       (lambda (m) (declare (ignore m))
                                                         (list (list :tool-use "id" 'delete-user nil)))))))
                    (spawn-agent! sup agent)
                    (sleep 0.05)
                    (let* ((reply   (ask-agent agent "go"))
                           (results (getf reply :tool-results)))
                      (check (= 1 (length results)))
                      (check (eq :vetoed (getf (first results) :status))
                             "delete-user blocked by reasoner verdict"))
                    (send! (agent-mailbox agent) :shutdown)
                    (sleep 0.05)
                    (drain-supervisor! sup))
               (uninstall-invariant-filter!))))
      (setf *reasoner-ipc-call* original))))

(defun test-invariant-filter-allows-permitted ()
  (format t "~%-- invariant-filter-allows-permitted --~%")
  (clear-all-hooks) (clear-all-tools)
  (define-tool greet :schema ()
    :handler (lambda (a) (declare (ignore a)) "hi"))
  (let ((original *reasoner-ipc-call*))
    (unwind-protect
         (progn
           (setf *reasoner-ipc-call*
                 (lambda (op &rest args)
                   (declare (ignore args))
                   (case op
                     (:load-theory :h-1)
                     (:query (%negative-result)))))
           (let ((handle (load-theory "..."))
                 (sup    (make-supervisor 'inv-sup-2 :max-restarts 3)))
             (install-invariant-filter! :theory-handle handle)
             (unwind-protect
                  (let ((agent (make-instance 'agent :id 'inv-a-2 :capability "x"
                                                      :tools '(greet)
                                                      :provider
                                                      (make-stub-provider
                                                       :responder
                                                       (lambda (m) (declare (ignore m))
                                                         (list (list :tool-use "id" 'greet nil)))))))
                    (spawn-agent! sup agent)
                    (sleep 0.05)
                    (let* ((reply   (ask-agent agent "go"))
                           (results (getf reply :tool-results)))
                      (check (= 1 (length results)))
                      (check (eq :ok (getf (first results) :status))
                             "greet allowed (reasoner -Δ)"))
                    (send! (agent-mailbox agent) :shutdown)
                    (sleep 0.05)
                    (drain-supervisor! sup))
               (uninstall-invariant-filter!))))
      (setf *reasoner-ipc-call* original))))

(defun %exercise-invariant-filter-failure (query-result-thunk test-id)
  "Run one guarded tool call while QUERY-RESULT-THUNK fails or returns evidence."
  (clear-all-hooks) (clear-all-tools)
  (let ((protected-calls 0)
        (original *reasoner-ipc-call*))
    (define-tool reasoner-guarded-tool
      :schema ()
      :handler (lambda (args)
                 (declare (ignore args))
                 (incf protected-calls)
                 :protected-action-ran))
    (unwind-protect
         (progn
           (setf *reasoner-ipc-call*
                 (lambda (op &rest args)
                   (declare (ignore args))
                   (case op
                     (:load-theory :spec-014-red-gate)
                     (:query (funcall query-result-thunk))
                     (otherwise :ok))))
           (let ((handle (load-theory "spec-014-red-gate")))
             (install-invariant-filter! :theory-handle handle)
             (unwind-protect
                  (let* ((agent
                           (make-instance
                            'agent
                            :id (intern (format nil "REASONER-~A" test-id)
                                        :anuna-imago.test)
                            :capability "reasoner:guarded"
                            :tools '(reasoner-guarded-tool)
                            :provider
                            (make-stub-provider
                             :responder
                             (lambda (message)
                               (declare (ignore message))
                               (list (list :tool-use "guarded-1"
                                           'reasoner-guarded-tool nil))))))
                         (reply (process-turn agent (make-ask "guarded action")))
                         (result (first (getf reply :tool-results))))
                    (check (eq :vetoed (getf result :status))
                           (format nil "~A denies the guarded dispatch" test-id))
                    (check (zerop protected-calls)
                           (format nil "~A leaves protected handler untouched" test-id)))
               (uninstall-invariant-filter!))))
      (uninstall-invariant-filter!)
      (setf *reasoner-ipc-call* original))))

(defun test-invariant-filter-fails-closed-on-query-error ()
  "SPEC-014 TEST-004: an installed filter denies on reasoner outage."
  (format t "~%-- invariant-filter-fails-closed-on-query-error (SPEC-014 TEST-004) --~%")
  (%exercise-invariant-filter-failure
   (lambda () (error "simulated reasoner outage"))
   "query error"))

(defun test-invariant-filter-fails-closed-on-malformed-evidence ()
  "SPEC-014 TEST-025: every malformed proof-result class denies."
  (format t "~%-- invariant-filter-fails-closed-on-malformed-evidence (SPEC-014 TEST-025) --~%")
  (dolist (case
           (list
            (list "nil evidence" nil)
            (list "atomic evidence" :not-a-proof-result)
            (list "odd plist" '(:tag :+delta :derivation))
            (list "missing proof tag" '(:derivation nil :time-ms 1))
            (list "unknown proof tag"
                  '(:tag :unknown-proof :derivation nil :time-ms 1))
            (list "duplicate key"
                  '(:tag :-delta :tag :-partial-delta
                    :derivation nil :time-ms 1))
            (list "unknown extra key"
                  '(:tag :-delta :derivation nil :time-ms 1 :extra t))
            (list "atomic derivation"
                  '(:tag :-delta :derivation rule-1 :time-ms 1))
            (list "improper derivation"
                  (list :tag :-delta :derivation (cons 'rule-1 'tail) :time-ms 1))
            (list "non-integer time"
                  '(:tag :-delta :derivation nil :time-ms 1.0))
            (list "negative time"
                  '(:tag :-delta :derivation nil :time-ms -1))))
    (destructuring-bind (description evidence) case
      (%exercise-invariant-filter-failure
       (lambda () evidence)
       description))))

;; ----------------------------------------------------- :clean integration ---

(defun test-invariant-filter-clean-drops-handle ()
  "register-credential-eraser! should clear *active-theory-handle* when
pre-save-clean! runs, so the handle doesn't leak into shipped images."
  (format t "~%-- invariant-filter-clean-drops-handle --~%")
  (let ((*reasoner-ipc-call* (lambda (op &rest args) (declare (ignore op args)) :h)))
    (install-invariant-filter! :theory-handle :h)
    (check (eq :h *active-theory-handle*))
    (pre-save-clean!)
    (check (null *active-theory-handle*)
           "pre-save-clean! cleared the active theory handle")
    (uninstall-invariant-filter!)))

;; ---------------------------------------------------------------- runner ---

(defun run-m10-tests ()
  (setf *failures* 0)
  (format t "~%=== M10 quality-gate tests ===~%")
  (test-reasoner-ipc-not-configured)
  (test-reasoner-load-theory)
  (test-reasoner-query)
  (test-invariant-filter-vetoes-forbidden)
  (test-invariant-filter-allows-permitted)
  (test-invariant-filter-fails-closed-on-query-error)
  (test-invariant-filter-fails-closed-on-malformed-evidence)
  (test-invariant-filter-clean-drops-handle)
  (format t "~%=== ~D failure(s) ===~%" *failures*)
  (when (plusp *failures*) (sb-ext:exit :code 1))
  (format t "M10 green.~%"))
