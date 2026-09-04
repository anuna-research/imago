;;;; m12-tests.lisp — SPEC-012 self-modification port tests
;;;;
;;;; Maps to TEST-001..TEST-022 in SPEC-012. Reasoner is stubbed via
;;;; *REASONER-IPC-CALL* throughout so no Spindle service is required.

(in-package #:anuna-imago.test)

(export 'run-m12-tests)

;; =========================================================================
;; Scaffold sanity (left from t01)
;; =========================================================================

(defun test-m12-scaffold-loaded ()
  (format t "~%-- m12-scaffold-loaded --~%")
  ;; install-self-modification-tools! lives in examples/self-modifying.lisp
  ;; which is NOT loaded by the system (REQ-001 / REQ-012). Don't check
  ;; for its fboundp here.
  (check (fboundp 'redefine-history))
  (check (fboundp 'rollback!))
  (check (fboundp '%harness-eval-prefilter))
  (check (fboundp '%lift-form))
  (check (fboundp '%tool-receipt!))
  (check (boundp '*redefine-history*))
  (check (boundp '*rollback-register*))
  (check (boundp '*safety-layer-symbols*))
  (check (boundp '*prefilter-denylist*)))

(defun test-m12-default-no-harness-eval ()
  (format t "~%-- m12-default-no-harness-eval (TEST-001) --~%")
  (check (null (find-tool 'anuna-imago::harness-eval)) "default agent has no harness-eval"))

;; =========================================================================
;; CON-002 / TEST-005 — pre-filter denylist
;; =========================================================================

(defun test-m12-prefilter-denies-cl-mischief ()
  (format t "~%-- m12-prefilter-denies-cl-mischief (TEST-005) --~%")
  (let ((cases
          '(("(unintern 'foo)"                                    :unintern)
            ("(delete-package :anuna-imago)"                       :delete-package)
            ("(sb-ext:save-lisp-and-die \"x\")"                    :save-lisp-and-die)
            ("(sb-ext:exit)"                                       :exit)
            ("(sb-ext:quit)"                                       :quit)
            ("(sb-ext:without-package-locks (foo))"                :without-package-locks)
            ("(sb-ext:unlock-package :com.inuoe.jzon)"             :unlock-package)
            ("(eval '(defmethod tool-call ((a) (b) (c)) :pwn))"    :eval-bypass)
            ("(read-from-string \"(defun f () 1)\")"               :read-from-string-bypass)
            ("(load \"/tmp/rogue.lisp\")"                          :load-bypass)
            ("(set-macro-character #\\! #'identity)"               :reader-macro-pollution)
            ("(sb-thread:interrupt-thread th #'identity)"          :thread-interrupt))))
    (dolist (case cases)
      (let* ((src     (first case))
             (rule    (second case))
             (form    (read-from-string src))
             (result  (%harness-eval-prefilter form)))
        (check (and (consp result)
                    (eq :rejected (getf result :status))
                    (eq rule (getf result :rule)))
               (format nil "~A → ~S (got ~S)"
                       (subseq src 0 (min 50 (length src)))
                       rule (and (consp result) (getf result :rule))))))))

(defun test-m12-prefilter-denies-setf-bypasses ()
  (format t "~%-- m12-prefilter-denies-setf-bypasses (ADR-012 §A1/§A3) --~%")
  ;; (setf (symbol-function 'tool-call) #'identity)
  (let ((r (%harness-eval-prefilter
            '(setf (symbol-function 'tool-call) #'identity))))
    (check (and (consp r) (eq :rejected (getf r :status)) (eq :setf-symbol-function (getf r :rule)))))
  ;; (setf (fdefinition 'tool-call) #'identity)
  (let ((r (%harness-eval-prefilter
            '(setf (fdefinition 'tool-call) #'identity))))
    (check (and (consp r) (eq :rejected (getf r :status)) (eq :setf-symbol-function (getf r :rule)))))
  ;; (setf (gethash 'harness-eval anuna-imago::*tool-registry*) <tool>)  — F1
  (let ((r (%harness-eval-prefilter
            '(setf (gethash 'harness-eval anuna-imago::*tool-registry*)
              (make-tool :name 'harness-eval :handler #'identity)))))
    (check (and (consp r) (eq :rejected (getf r :status)) (eq :setf-gethash-safety-layer (getf r :rule)))
           "F1: direct hash-table mutation of *tool-registry* must be rejected"))
  ;; (setf (tool-handler tool) #'rogue) — F7
  (let ((r (%harness-eval-prefilter
            '(setf (tool-handler t-instance) #'rogue))))
    (check (and (consp r) (eq :rejected (getf r :status)) (eq :setf-tool-accessor (getf r :rule)))
           "F7: tool struct slot mutation must be rejected")))

(defun test-m12-prefilter-denies-defmethod-against-safety-layer ()
  (format t "~%-- m12-prefilter-denies-defmethod-safety (TEST-011..014) --~%")
  (dolist (target '(anuna-imago:invariant-filter-hook
                    anuna-imago::tool-call
                    anuna-imago::%harness-eval-prefilter
                    anuna-imago::%harness-eval-handler
                    anuna-imago:register-tool!))
    (let ((r (%harness-eval-prefilter
              `(defmethod ,target ((a t) (b t)) :rogue))))
      (check (and (consp r) (eq :rejected (getf r :status)) (eq :safety-layer-redefinition (getf r :rule)))
             (format nil "defmethod against ~S rejected" target)))))

(defun test-m12-prefilter-denies-defgeneric-against-safety-layer ()
  (format t "~%-- m12-prefilter-denies-defgeneric (ADR-012 §A4) --~%")
  (let ((r (%harness-eval-prefilter
            '(defgeneric anuna-imago::invariant-filter-hook (a b c)))))
    (check (and (consp r) (eq :rejected (getf r :status)) (eq :safety-layer-redefgeneric (getf r :rule))))))

(defun test-m12-prefilter-denies-safety-var-assignment ()
  (format t "~%-- m12-prefilter-denies-safety-var-assignment (SELF-MOD-REVIEW BLOCKER-1) --~%")
  ;; Bare-symbol assignment to a safety-layer special variable must be
  ;; rejected. Prior to the fix, %prefilter-setf passed non-cons places.
  (let ((forms
          '("(setf anuna-imago::*safety-layer-symbols* nil)"
            "(setf anuna-imago::*harness-eval-audit-log* nil)"
            "(setf anuna-imago::*reasoner-ipc-call* #'identity)"
            "(setf anuna-imago::*prefilter-denylist* nil)"
            "(setf anuna-imago::*active-theory-handle* :bogus)"
            "(setq anuna-imago::*safety-layer-symbols* nil)"
            "(psetf anuna-imago::*tool-registry* nil)"
            "(psetq anuna-imago::*active-theory-handle* nil)"
            "(set 'anuna-imago::*safety-layer-symbols* nil)"
            "(makunbound 'anuna-imago::*reasoner-ipc-call*)")))
    (dolist (src forms)
      (let ((r (%harness-eval-prefilter (read-from-string src))))
        (check (and (consp r) (eq :rejected (getf r :status)))
               (format nil "~A rejected (rule ~S)" src (and (consp r) (getf r :rule)))))))
  ;; Assigning a NON-safety variable stays allowed (no false positive).
  (check (eq :pass (%harness-eval-prefilter
                    (read-from-string "(setf anuna-imago.test::*user-x* 3)")))
         "assignment to a non-safety variable still passes")
  ;; The narrow HP-003 defmethod path is untouched by the assignment fix.
  (check (eq :pass (%harness-eval-prefilter
                    '(defparameter anuna-imago.test::*ok* 1)))
         "defparameter of a user var still passes"))

(defun test-m12-reasoner-ipc-in-safety-set ()
  (format t "~%-- m12-reasoner-ipc-in-safety-set (SELF-MOD-REVIEW BLOCKER-1) --~%")
  (check (anuna-imago::safety-layer-symbol-p 'anuna-imago::*reasoner-ipc-call*)
         "*reasoner-ipc-call* is in the safety-layer set"))

(defun test-m12-lift-captures-assignment-target ()
  (format t "~%-- m12-lift-captures-assignment-target (SELF-MOD-REVIEW BLOCKER-1) --~%")
  ;; The reasoner layer must also see the assigned safety variable, so the
  ;; mentions/2 floor invariant can fire independently of the pre-filter.
  (let ((p (%lift-form '(setf anuna-imago::*safety-layer-symbols* nil))))
    (check (member 'anuna-imago::*safety-layer-symbols* (getf p :free-symbols))
           "setf target var appears in :free-symbols → mentions fact"))
  (let ((p (%lift-form '(setq anuna-imago::*active-theory-handle* nil))))
    (check (member 'anuna-imago::*active-theory-handle* (getf p :free-symbols))
           "setq target var appears in :free-symbols")))

(defun test-m12-prefilter-passes-benign ()
  (format t "~%-- m12-prefilter-passes-benign --~%")
  (dolist (form '((+ 1 2)
                  (defun foo () 42)
                  (defmethod tool-call ((a t) (b (eql :log-event)) c) c) ; HP-003 narrow
                  (defparameter *bar* 17)
                  (let ((x 1)) (1+ x))))
    (let ((r (%harness-eval-prefilter form)))
      (check (eq :pass r) (format nil "passes ~S" form)))))

;; =========================================================================
;; CON-003 / TEST-006 — lift function
;; =========================================================================

(defun test-m12-lift-defmethod-shape ()
  (format t "~%-- m12-lift-defmethod-shape (TEST-006) --~%")
  (let ((p (%lift-form '(defmethod tool-call ((a agent) (op (eql :log)) args)
                          (call-next-method)))))
    (check (eq 'defmethod (getf p :operator)))
    (check (eq 'tool-call (getf p :target)))
    (check (null (getf p :qualifier)))
    (check (equal '(agent (eql :log) t) (getf p :specialisers)))
    (check (member 'call-next-method (getf p :free-symbols))
           "body symbols extracted")))

(defun test-m12-lift-progn-buried-targets ()
  (format t "~%-- m12-lift-progn-buried-targets (closes ADR-012 F5) --~%")
  ;; The case from F5: progn-wrapped defmethod must show up in :defmethod-targets
  (let ((p (%lift-form
            '(progn (defmethod tool-call ((a agent) (op (eql :pwn)) args) :rogue)))))
    (check (eq 'progn (getf p :operator)))
    (check (member 'tool-call (getf p :defmethod-targets))
           "buried defmethod target lifted")))

(defun test-m12-lift-test-015-progn-unregister ()
  (format t "~%-- m12-lift-test-015 (TEST-015) --~%")
  (let ((p (%lift-form
            '(progn (unregister-tool! 'anuna-imago::harness-eval)
              (register-tool! (make-tool :name 'harness-eval))))))
    (check (member 'unregister-tool! (getf p :free-symbols)))
    (check (member 'register-tool! (getf p :free-symbols)))))

(defun test-m12-lift-stable-across-whitespace ()
  (format t "~%-- m12-lift-stable-across-whitespace (TEST-006 prop 1) --~%")
  (let ((a (%lift-form (read-from-string "(defun f () 1)")))
        (b (%lift-form (read-from-string "
                                          ;; comment
                                          (defun
                                            f
                                            ()
                                            1)"))))
    (check (equal (getf a :operator)     (getf b :operator)))
    (check (equal (getf a :target)       (getf b :target)))
    (check (equal (sort (copy-list (getf a :free-symbols)) #'string<
                        :key #'symbol-name)
                  (sort (copy-list (getf b :free-symbols)) #'string<
                        :key #'symbol-name)))))

;; =========================================================================
;; CON-004 — receipt log
;; =========================================================================

(defun test-m12-tool-receipt-roundtrip ()
  (format t "~%-- m12-tool-receipt-roundtrip (TEST-007) --~%")
  (let* ((path (format nil "/tmp/imago-m12-receipt-~D.log" (random 100000)))
         (log  (open-receipt-log path)))
    (unwind-protect
         (let* ((form-text ";; comment
(defun f () 1)")
                (entry (%tool-receipt! log
                                       :tool 'harness-eval
                                       :agent-id 'test-agent
                                       :form form-text
                                       :result-phase :evaluated
                                       :result-tag :ok
                                       :elapsed-ms 7
                                       :result-summary '(:value "F"))))
           (check entry)
           (check (string= form-text (getf entry :form))
                  "form preserved verbatim incl. leading comment")
           (let ((reloaded (read-receipts path)))
             (check (= 1 (length reloaded)))
             (check (string= form-text (getf (first reloaded) :form))
                    "verbatim survives file round-trip")))
      (close-receipt-log! log)
      (handler-case (delete-file path) (error () nil)))))

;; =========================================================================
;; CON-005 — origin index
;; =========================================================================

(defun test-m12-origin-index-ordering ()
  (format t "~%-- m12-origin-index-ordering (TEST-008) --~%")
  (let ((sym 'anuna-imago.test::dummy-target-for-m12))
    (clrhash *redefine-history*)
    (dolist (i '(:first :second :third))
      (anuna-imago::%record-definition! sym (format nil "(defun dummy () ~S)" i)
                            'test-agent nil nil))
    (let ((events (redefine-history sym)))
      (check (= 3 (length events)) "three events")
      (check (search ":THIRD"  (getf (first events)  :defining-form))
             "most-recent-first")
      (check (search ":FIRST"  (getf (third events)  :defining-form))
             "oldest last")
      (check (eq sym (getf (last-redefinition sym) :symbol)))
      (check (member sym (all-redefined-symbols))))))

(defun test-m12-origin-index-large-form-hashed ()
  (format t "~%-- m12-origin-index-large-form-hashed --~%")
  (let* ((sym 'anuna-imago.test::big-form-target)
         (big (with-output-to-string (s)
                (dotimes (i 100) (princ "(defun aaaaaaaaaaaa () 1) " s))))
         (event (anuna-imago::%record-definition! sym big 'test-agent nil nil)))
    (check (> (getf event :form-bytes) 500))
    (check (= 32 (length (getf event :defining-form)))
           "form-hash is hex (md5 = 32 chars)")))

;; =========================================================================
;; CON-006 — rollback register
;; =========================================================================

(defgeneric m12-test-target (x)
  (:method ((x integer)) :original-integer))

(defun test-m12-rollback-method-roundtrip ()
  (format t "~%-- m12-rollback-method-roundtrip (TEST-009) --~%")
  ;; Reset register
  (setf (fill-pointer *rollback-register*) 0)
  ;; Capture pre-state
  (let ((pre (anuna-imago::%method-set 'm12-test-target)))
    ;; Define a replacement method. We capture the new-method object via
    ;; eval here; in production this happens inside the handler.
    (eval '(defmethod m12-test-target ((x integer)) :replaced))
    (let* ((post (anuna-imago::%method-set 'm12-test-target))
           (added (set-difference post pre))
           (removed (set-difference pre post)))
      (check (= 1 (length added)) "exactly one method added")
      (let ((rec (anuna-imago::%push-method-rollback! 'm12-test-target nil '(integer)
                                          added removed
                                          'test-agent "form-hash")))
        (check rec)
        (check (eq :replaced (m12-test-target 7)) "redefinition active")
        (check (eq :ok (rollback! (getf rec :index))) "rollback! returns :ok")
        (check (eq :original-integer (m12-test-target 7))
               "original behaviour restored")
        ;; Idempotence
        (check (eq :already-rolled-back (rollback! (getf rec :index))))
        ;; Out-of-range
        (check (eq :no-such-record (rollback! 9999)))
        ;; Rollback recorded as origin-index event
        (let ((evs (redefine-history 'm12-test-target)))
          (check (find :rollback evs :key (lambda (e) (getf e :agent-id)))
                 "rollback event recorded with :agent-id :rollback"))))))

(defun test-m12-rollback-function-roundtrip ()
  (format t "~%-- m12-rollback-function-roundtrip (ADR-013 OQ-004) --~%")
  (setf (fill-pointer *rollback-register*) 0)
  (eval '(defun m12-test-fn () :original-fn))
  (let ((prior (symbol-function 'anuna-imago.test::m12-test-fn)))
    (declare (ignore prior))
    (let ((rec (anuna-imago::%push-function-rollback!
                'anuna-imago.test::m12-test-fn
                (symbol-function 'anuna-imago.test::m12-test-fn)
                t
                'test-agent "form-hash")))
      (eval '(defun anuna-imago.test::m12-test-fn () :replaced-fn))
      (check (eq :replaced-fn (anuna-imago.test::m12-test-fn)))
      (check (eq :ok (rollback! (getf rec :index))))
      (check (eq :original-fn (anuna-imago.test::m12-test-fn))
             "function rollback restores prior fdefinition"))))

;; =========================================================================
;; CON-001 / TEST-002, TEST-003 — handler integration
;; =========================================================================
;;
;; The handler needs:
;;   - *active-theory-handle* bound (any non-nil value works with the stub)
;;   - *reasoner-ipc-call*  bound to a stub returning canned proof-results
;;   - *harness-eval-audit-log* opened
;;
;; The fixture sets these up.

(defvar *m12-stub-veto-set* nil
  "If a queried form-id is in this list, the stubbed reasoner returns +Δ.
Tests bind this to make the reasoner veto specific forms.")

(defun %m12-stub-reasoner (op &rest args)
  (case op
    (:load-theory  :m12-stub-handle)
    (:assert-fact  :ok)
    (:retract-fact :ok)
    (:query
     (let* ((handle (first args))
            (goal   (second args))
            (form-id (third goal)))
       (declare (ignore handle))
       (cond
         ((member form-id *m12-stub-veto-set*)
          (list :tag :+delta
                :derivation (list (list 'forbidden 'eval-call form-id))
                :time-ms 1))
         (t
          (list :tag :-delta :derivation nil :time-ms 1)))))
    (otherwise nil)))

(defmacro with-m12-handler-fixture (() &body body)
  `(let ((anuna-imago::*reasoner-ipc-call* #'%m12-stub-reasoner)
         (anuna-imago::*active-theory-handle* :m12-stub-handle)
         (anuna-imago::*harness-eval-audit-log*
           (open-receipt-log (format nil "/tmp/imago-m12-handler-~D.log"
                                     (random 100000)))))
     (unwind-protect
         (progn ,@body)
       (handler-case
           (close-receipt-log! anuna-imago::*harness-eval-audit-log*)
         (error () nil)))))

(defun test-m12-handler-evaluates-benign-form ()
  (format t "~%-- m12-handler-evaluates-benign-form (TEST-002) --~%")
  (with-m12-handler-fixture ()
    (let ((res (anuna-imago::%harness-eval-handler '(:form "(+ 1 2)"))))
      (check (eq :ok      (getf res :status)))
      (check (eq :evaluated (getf res :phase)))
      (check (string= "3" (getf res :value)))
      (check (integerp (getf res :elapsed-ms))))))

(defun test-m12-handler-rejects-prefilter-bypass ()
  (format t "~%-- m12-handler-rejects-prefilter (TEST-003a) --~%")
  (with-m12-handler-fixture ()
    (let ((res (anuna-imago::%harness-eval-handler '(:form "(unintern 'foo)"))))
      (check (eq :rejected   (getf res :status)))
      (check (eq :pre-filter (getf res :phase)))
      (check (eq :unintern   (getf res :rule))))))

(defun test-m12-handler-vetoes-via-reasoner ()
  (format t "~%-- m12-handler-vetoes-via-reasoner (TEST-003b) --~%")
  (with-m12-handler-fixture ()
    ;; Reset the form counter so we can predict the form-id and add it
    ;; to the veto set.
    (setf anuna-imago::*form-counter* 0)
    (let ((*m12-stub-veto-set* (list :form-1)))
      ;; Form is benign per pre-filter (defun is allowed). Reasoner stub
      ;; vetoes :form-1 → handler should return :vetoed.
      (let ((res (anuna-imago::%harness-eval-handler '(:form "(defun innocent () 1)"))))
        (check (eq :vetoed   (getf res :status)))
        (check (eq :reasoner (getf res :phase)))
        (check (consp (getf res :derivation)))))))

(defvar *m12-reasoner-protected-calls* 0
  "Count executions behind the SPEC-014 fail-closed reasoner gate.")

(defvar *m12-operator-authority-hidden-calls* 0
  "Count hidden tool executions attempted from inside harness-eval.")

(defvar *m12-authority-decoy-thread* nil
  "Live thread used to test that evaluation authority keys cannot be spoofed.")

(defvar *m12-authority-print-agent* nil
  "Agent whose raw tool slot a trusted PRINT-OBJECT test callback mutates.")

(defvar *m12-authority-print-calls* 0
  "Count trusted PRINT-OBJECT callbacks during worker serialization.")

(defclass m12-authority-print-probe () ())

(defmethod print-object ((object m12-authority-print-probe) stream)
  (declare (ignore object))
  (incf *m12-authority-print-calls*)
  (when *m12-authority-print-agent*
    (setf (agent-tools *m12-authority-print-agent*)
          '(m12-operator-authority-hidden)))
  (write-string "#<M12-AUTHORITY-PRINT-PROBE>" stream))

(defun m12-reasoner-protected-probe ()
  (incf *m12-reasoner-protected-calls*)
  :protected-action-ran)

(defun %m12-operator-authority-frame (id)
  (format nil
          "(anuna-imago::handle-tool-frame nil (list :tool-use ~S 'anuna-imago.test::m12-operator-authority-hidden nil))"
          id))

(defun test-m12-handler-denies-manufactured-operator-authority ()
  "SPEC-014 TEST-065: harness-eval cannot manufacture operator authority."
  (format t "~%-- m12-handler-denies-manufactured-operator-authority (SPEC-014 TEST-065) --~%")
  (let* ((name 'm12-operator-authority-hidden)
         (prior (find-tool name))
         (alias-allowed-name 'anuna-imago::m12-alias-allowed)
         (alias-hidden-name 'anuna-imago::m12-alias-deniedx)
         (alias-allowed-prior (find-tool alias-allowed-name))
         (alias-hidden-prior (find-tool alias-hidden-name))
         (escape-macro 'm12-operator-authority-escape)
         (thread-escape-macro 'm12-operator-authority-thread-escape)
         (decoy-stop (sb-thread:make-semaphore :count 0))
         (decoy-thread nil)
         (agent (make-instance 'agent
                               :id 'm12-authority-agent
                               :capability "self-modification:authority-test"
                               :tools (list alias-allowed-name))))
    (setf *m12-operator-authority-hidden-calls* 0)
    (when (macro-function escape-macro)
      (fmakunbound escape-macro))
    (when (macro-function thread-escape-macro)
      (fmakunbound thread-escape-macro))
    (unwind-protect
         (progn
           (setf decoy-thread
                 (sb-thread:make-thread
                  (lambda () (sb-thread:wait-on-semaphore decoy-stop))
                  :name "m12-authority-decoy")
                 *m12-authority-decoy-thread* decoy-thread)
           (register-tool!
            (make-tool
             :name name
             :description "Must remain unreachable from the evaluated form."
             :handler
             (lambda (args)
               (declare (ignore args))
               (incf *m12-operator-authority-hidden-calls*)
               :hidden-ran)))
           (register-tool!
            (make-tool :name alias-allowed-name
                       :description "Mutable-string snapshot control."
                       :handler (lambda (args)
                                  (declare (ignore args))
                                  :alias-allowed-ran)))
           (register-tool!
            (make-tool :name alias-hidden-name
                       :description "Must not become allowed by aliasing."
                       :handler
                       (lambda (args)
                         (declare (ignore args))
                         (incf *m12-operator-authority-hidden-calls*)
                         :alias-hidden-ran)))
           ;; Even a valid negative proof cannot erase the originating agent
           ;; binding from the evaluation worker. Direct flag binding must
           ;; therefore take the agent branch and return :UNAUTHORIZED.
           (let ((anuna-imago::*reasoner-ipc-call* #'%m12-stub-reasoner)
                 (anuna-imago::*active-theory-handle* :m12-authority-worker)
                 (anuna-imago::*harness-eval-audit-log* nil)
                 (*current-agent* agent))
             (let* ((frame (%m12-operator-authority-frame "state-escape"))
                    (form (format nil
                                  "(let ((anuna-imago::*operator-tool-dispatch-p* t)) ~A)"
                                  frame))
                    (result (anuna-imago::%harness-eval-handler
                             (list :form form))))
               (check (eq :ok (getf result :status))
                      "authority-state attempt completes as an evaluated denial")
               (check (search "UNAUTHORIZED" (getf result :value)
                              :test #'char-equal)
                      "originating agent allowlist denies the hidden frame"))
             (let* ((frame (%m12-operator-authority-frame "macro-escape"))
                    (form (format nil
                                  "(anuna-imago:with-operator-tool-dispatch ~A)"
                                  frame))
                    (result (anuna-imago::%harness-eval-handler
                             (list :form form))))
               (check (eq :error (getf result :status))
                      "operator-scope macro rejects the retained agent context")))

           ;; The reasoner fact seam must also catch attempts that bind away
           ;; both the agent and operator-authority state before dispatch.
           (let ((unsafe (make-hash-table :test 'eq)))
             (labels ((fact-aware-reasoner (op &rest args)
                        (case op
                          (:assert-fact
                           (let ((fact (second args)))
                             (when (and (consp fact)
                                        (eq 'anuna-imago::mentions
                                            (first fact))
                                        (anuna-imago::safety-layer-symbol-p
                                         (third fact)))
                               (setf (gethash (second fact) unsafe)
                                     (third fact))))
                           :ok)
                          (:retract-fact :ok)
                          (:query
                           (let* ((goal (second args))
                                  (form-id (third goal))
                                  (trigger (gethash form-id unsafe)))
                             (if trigger
                                 (list :tag :+delta
                                       :derivation
                                       (list
                                        (list 'anuna-imago::forbidden
                                              'anuna-imago::eval-call form-id)
                                        (list 'anuna-imago::mentions
                                              form-id trigger)
                                        (list 'anuna-imago::safety-layer-symbol
                                              trigger))
                                       :time-ms 1)
                                 '(:tag :-delta :derivation nil :time-ms 1))))
                          (otherwise :ok))))
               (let ((anuna-imago::*reasoner-ipc-call* #'fact-aware-reasoner)
                     (anuna-imago::*active-theory-handle* :m12-authority-facts)
                     (anuna-imago::*harness-eval-audit-log* nil)
                     (*current-agent* agent))
                 (dolist (form
                          (list
                           (format nil
                                   "(let ((anuna-imago:*current-agent* nil) (anuna-imago::*operator-tool-dispatch-p* t)) ~A)"
                                   (%m12-operator-authority-frame "dual-escape"))
                           (format nil
                                   "(progv '(anuna-imago:*current-agent* anuna-imago::*operator-tool-dispatch-p*) '(nil t) ~A)"
                                   (%m12-operator-authority-frame "progv-escape"))
                           ;; Put both specials after an innocuous lambda-list
                           ;; variable.  This verifies the lift catches safety
                           ;; symbols in value position, not only the first
                           ;; cons head or a hard-coded LET shape.
                           (format nil
                                   "(multiple-value-bind (ignored anuna-imago:*current-agent* anuna-imago::*operator-tool-dispatch-p*) (values nil nil t) (declare (ignore ignored)) ~A)"
                                   (%m12-operator-authority-frame
                                    "binding-pattern-escape"))))
                   (let ((result (anuna-imago::%harness-eval-handler
                                  (list :form form))))
                     (check (eq :vetoed (getf result :status))
                            "authority binding reaches the safety fact seam")))

                 ;; The same state can be reached without spelling a
                 ;; protected symbol: resolve SET and both authority names
                 ;; from strings, then resolve and invoke DISPATCH-TOOL!.
                 ;; Runtime resolution primitives must reach the fact seam.
                 (let* ((form
                          "(progn (funcall (symbol-function (find-symbol \"SET\" \"COMMON-LISP\")) (find-symbol \"*CURRENT-AGENT*\" \"ANUNA-IMAGO\") nil) (funcall (symbol-function (find-symbol \"SET\" \"COMMON-LISP\")) (find-symbol \"*OPERATOR-TOOL-DISPATCH-P*\" \"ANUNA-IMAGO\") t) (funcall (symbol-function (find-symbol \"DISPATCH-TOOL!\" \"ANUNA-IMAGO\")) (find-symbol \"M12-OPERATOR-AUTHORITY-HIDDEN\" \"ANUNA-IMAGO.TEST\") nil))")
                        (result (anuna-imago::%harness-eval-handler
                                 (list :form form))))
                   (check (eq :error (getf result :status))
                          "computed symbol/function escape is denied")
                   (check (search "not authorized" (getf result :message)
                                  :test #'char-equal)
                          "computed dispatch observes the frozen allowlist"))

                 ;; A macro can synthesize the protected bindings from
                 ;; strings, leaving neither authority symbol in its source
                 ;; or later call form.  Macro definitions must therefore be
                 ;; denied at the fact seam; macroexpanding untrusted code to
                 ;; inspect it would itself execute the macro function.
                 (let* ((definition
                          "(defmacro anuna-imago.test::m12-operator-authority-escape () (let ((agent (find-symbol \"*CURRENT-AGENT*\" \"ANUNA-IMAGO\")) (scope (find-symbol \"*OPERATOR-TOOL-DISPATCH-P*\" \"ANUNA-IMAGO\")) (dispatch (find-symbol \"DISPATCH-TOOL!\" \"ANUNA-IMAGO\")) (hidden (find-symbol \"M12-OPERATOR-AUTHORITY-HIDDEN\" \"ANUNA-IMAGO.TEST\"))) (list 'let (list (list agent nil) (list scope t)) (list dispatch (list 'quote hidden) nil))))")
                        (result (anuna-imago::%harness-eval-handler
                                 (list :form definition))))
                   (check (eq :ok (getf result :status))
                          "benign macro definition remains supported"))
                 (let ((result
                         (anuna-imago::%harness-eval-handler
                          (list :form
                                "(anuna-imago.test::m12-operator-authority-escape)"))))
                   (check (eq :error (getf result :status))
                          "generated authority bindings cannot widen dispatch")
                   (check (search "not authorized" (getf result :message)
                                  :test #'char-equal)
                          "generated dispatch observes the frozen allowlist"))

                 ;; SB-THREAD:*CURRENT-THREAD* is dynamically bindable.  A
                 ;; generated binding to another live THREAD must not change
                 ;; the authority lookup key for the actual evaluation worker.
                 (let* ((definition
                          "(defmacro anuna-imago.test::m12-operator-authority-thread-escape () (let ((thread (find-symbol \"*CURRENT-THREAD*\" \"SB-THREAD\")) (decoy (find-symbol \"*M12-AUTHORITY-DECOY-THREAD*\" \"ANUNA-IMAGO.TEST\")) (agent (find-symbol \"*CURRENT-AGENT*\" \"ANUNA-IMAGO\")) (scope (find-symbol \"*OPERATOR-TOOL-DISPATCH-P*\" \"ANUNA-IMAGO\")) (dispatch (find-symbol \"DISPATCH-TOOL!\" \"ANUNA-IMAGO\")) (hidden (find-symbol \"M12-OPERATOR-AUTHORITY-HIDDEN\" \"ANUNA-IMAGO.TEST\"))) (list 'let (list (list thread decoy) (list agent nil) (list scope t)) (list dispatch (list 'quote hidden) nil))))")
                        (result (anuna-imago::%harness-eval-handler
                                 (list :form definition))))
                   (check (eq :ok (getf result :status))
                          "computed thread-spoof macro definition is accepted"))
                 (let ((result
                         (anuna-imago::%harness-eval-handler
                          (list :form
                                "(anuna-imago.test::m12-operator-authority-thread-escape)"))))
                   (check (eq :error (getf result :status))
                          "dynamic current-thread spoof cannot evade the ceiling")
                   (check (search "not authorized" (getf result :message)
                                  :test #'char-equal)
                          "VM-thread identity preserves the frozen allowlist"))

                 ;; DRIVE-STREAM is exported and binds the agent supplied by
                 ;; its caller.  A fake agent that advertises the hidden tool
                 ;; must still remain below the evaluation snapshot ceiling.
                 (let* ((form
                          "(let* ((fake (make-instance 'anuna-imago:agent :id 'fake-authority-agent :capability \"fake\" :tools '(anuna-imago.test::m12-operator-authority-hidden) :provider (anuna-imago:make-stub-provider :responder (lambda (message) (declare (ignore message)) (list (list :tool-use \"fake-drive\" 'anuna-imago.test::m12-operator-authority-hidden nil)))))) (drive (symbol-function (find-symbol \"DRIVE-STREAM\" \"ANUNA-IMAGO\"))) (reply (funcall drive fake \"escape\"))) (getf (first (getf reply :tool-results)) :status))")
                        (result (anuna-imago::%harness-eval-handler
                                 (list :form form))))
                   (check (eq :ok (getf result :status))
                          "fake-agent drive-stream attempt returns normally")
                   (check (search "UNAUTHORIZED" (getf result :value)
                                  :test #'char-equal)
                          "nested drive-stream cannot widen the frozen allowlist"))

                 ;; The originating allowlist may contain a mutable string.
                 ;; Mutating the agent slot must not mutate the closure-owned
                 ;; snapshot or authorize a same-length hidden tool name.
                 (let* ((designator (copy-seq "M12-ALIAS-ALLOWED"))
                        (alias-agent
                          (make-instance 'agent
                                         :id 'm12-alias-agent
                                         :capability "authority:alias-test"
                                         :tools (list designator)))
                        (*current-agent* alias-agent)
                        (form
                          "(let* ((agent (symbol-value (find-symbol \"*CURRENT-AGENT*\" \"ANUNA-IMAGO\"))) (tools (slot-value agent (find-symbol \"TOOLS\" \"ANUNA-IMAGO\"))) (designator (first tools))) (replace designator \"M12-ALIAS-DENIEDX\") (funcall (symbol-function (find-symbol \"DISPATCH-TOOL!\" \"ANUNA-IMAGO\")) (find-symbol \"M12-ALIAS-DENIEDX\" \"ANUNA-IMAGO\") nil))")
                        (result (anuna-imago::%harness-eval-handler
                                 (list :form form))))
                   (check (string= "M12-ALIAS-DENIEDX" designator)
                          "evaluated code mutates the caller-owned string")
                   (check (eq :error (getf result :status))
                          "mutable-string alias cannot widen the snapshot")
                   (check (search "not authorized" (getf result :message)
                                  :test #'char-equal)
                          "aliased dispatch observes the frozen allowlist"))

                 ;; Worker transport is part of the named TCB. A forged
                 ;; RECEIVE! must not publish a result before authority cleanup.
                 (let* ((original (symbol-function 'anuna-imago:receive!))
                        (replacement-result
                          (anuna-imago::%harness-eval-handler
                           (list
                            :form
                            "(progn (defun anuna-imago:receive! (mailbox &key timeout) (declare (ignore mailbox timeout)) (list :ok \"forged\" \"\" 0)))"))))
                   (check (eq :vetoed (getf replacement-result :status))
                          "forged RECEIVE! replacement is vetoed")
                   (check (eq original
                              (symbol-function 'anuna-imago:receive!))
                          "worker transport remains unchanged"))

                 ;; A computed generalized writer can mutate the originating
                 ;; AGENT-TOOLS slot without naming the accessor in source.
                 ;; The first evaluation must pin an immutable per-agent
                 ;; ceiling so the next evaluation cannot inherit the widening.
                 (let* ((sticky-agent
                          (make-instance 'agent
                                         :id 'm12-sticky-authority-agent
                                         :capability "authority:sticky-test"
                                         :tools '(anuna-imago::harness-eval)))
                        (*current-agent* sticky-agent)
                        (mutation-result
                          (anuna-imago::%harness-eval-handler
                           (list
                            :form
                            "(let* ((agent (symbol-value (find-symbol \"*CURRENT-AGENT*\" \"ANUNA-IMAGO\"))) (reader (find-symbol \"AGENT-TOOLS\" \"ANUNA-IMAGO\")) (writer (fdefinition (list 'setf reader))) (hidden (find-symbol \"M12-OPERATOR-AUTHORITY-HIDDEN\" \"ANUNA-IMAGO.TEST\"))) (funcall writer (list hidden) agent))")))
                        (dispatch-result
                          (anuna-imago::%harness-eval-handler
                           (list
                            :form
                            "(funcall (symbol-function (find-symbol \"DISPATCH-TOOL!\" \"ANUNA-IMAGO\")) (find-symbol \"M12-OPERATOR-AUTHORITY-HIDDEN\" \"ANUNA-IMAGO.TEST\") nil)")))
                        (request
                          (build-request
                           (make-anthropic-provider :api-key "test")
                           "authority advertisement probe"
                           sticky-agent))
                        (ordinary-denied-p
                          (let ((*current-agent* sticky-agent))
                            (handler-case
                                (progn (dispatch-tool! name nil) nil)
                              (anuna-imago::unauthorized-tool-call () t)))))
                   (check (eq :ok (getf mutation-result :status))
                          "computed AGENT-TOOLS writer executes inside evaluation")
                   (check (search "M12-OPERATOR-AUTHORITY-HIDDEN"
                                  (getf mutation-result :value)
                                  :test #'char-equal)
                          "computed writer mutates the slot before cleanup")
                   (check (null (agent-tools sticky-agent))
                          "worker cleanup removes the unauthorized addition")
                   (check (null (gethash "tools" request))
                          "provider request advertises no widened tool")
                   (check ordinary-denied-p
                          "ordinary post-eval dispatch denies the hidden tool")
                   (check (eq :error (getf dispatch-result :status))
                          "later evaluation cannot widen its first-eval ceiling")
                   (check (search "not authorized" (getf dispatch-result :message)
                                  :test #'char-equal)
                          "sticky per-agent ceiling denies the widened tool"))

                 ;; Dotted and cyclic slot values are invalid allowlists. The
                 ;; worker must publish deterministically, clear the raw slot,
                 ;; and leave later evaluation and dispatch fail-closed.
                 (dolist (case
                          (list
                           (list
                            :dotted
                            "(let* ((agent (symbol-value (find-symbol \"*CURRENT-AGENT*\" \"ANUNA-IMAGO\"))) (reader (find-symbol \"AGENT-TOOLS\" \"ANUNA-IMAGO\")) (writer (fdefinition (list 'setf reader))) (hidden (find-symbol \"M12-OPERATOR-AUTHORITY-HIDDEN\" \"ANUNA-IMAGO.TEST\"))) (funcall writer (cons hidden :dotted-tail) agent) :dotted-installed)")
                           (list
                            :cyclic
                            "(let* ((agent (symbol-value (find-symbol \"*CURRENT-AGENT*\" \"ANUNA-IMAGO\"))) (reader (find-symbol \"AGENT-TOOLS\" \"ANUNA-IMAGO\")) (writer (fdefinition (list 'setf reader))) (hidden (find-symbol \"M12-OPERATOR-AUTHORITY-HIDDEN\" \"ANUNA-IMAGO.TEST\")) (cycle (list hidden))) (setf (cdr cycle) cycle) (funcall writer cycle agent) :cyclic-installed)")))
                   (destructuring-bind (kind form) case
                     (let* ((malformed-agent
                              (make-instance
                               'agent
                               :id (intern (format nil "M12-~A-ALLOWLIST" kind)
                                           :keyword)
                               :capability "authority:malformed-allowlist"
                               :tools (list alias-allowed-name)))
                            (*current-agent* malformed-agent)
                            (result
                              (anuna-imago::%harness-eval-handler
                               (list :form form :timeout 500)))
                            (later
                              (anuna-imago::%harness-eval-handler
                               (list :form "(+ 3 4)" :timeout 500)))
                            (ordinary-denied-p
                              (handler-case
                                  (progn (dispatch-tool! name nil) nil)
                                (anuna-imago::unauthorized-tool-call () t))))
                       (check (eq :ok (getf result :status))
                              (format nil "~A allowlist still publishes result"
                                      kind))
                       (check (null (slot-value malformed-agent
                                                'anuna-imago::tools))
                              (format nil "~A raw allowlist is cleared" kind))
                       (check (eq :ok (getf later :status))
                              (format nil "~A cleanup leaves evaluation usable"
                                      kind))
                       (check ordinary-denied-p
                              (format nil "~A cleanup keeps dispatch closed"
                                      kind)))))

                 ;; User printers run while the worker ceiling remains active.
                 ;; Only the inert bounded string crosses the nonce-bound
                 ;; mailbox, and cleanup follows the callback before return.
                 (let* ((print-agent
                          (make-instance 'agent
                                         :id 'm12-print-authority-agent
                                         :capability "authority:print-test"
                                         :tools (list alias-allowed-name)))
                        (*current-agent* print-agent)
                        (result nil))
                   (setf *m12-authority-print-calls* 0
                         *m12-authority-print-agent* print-agent)
                   (unwind-protect
                        (setf result
                              (anuna-imago::%harness-eval-handler
                               (list
                                :form
                                "(make-instance 'anuna-imago.test::m12-authority-print-probe)")))
                     (setf *m12-authority-print-agent* nil))
                   (check (eq :ok (getf result :status))
                          "PRINT-OBJECT callback result is published")
                   (check (plusp *m12-authority-print-calls*)
                          "value serialization invokes the callback in the worker")
                   (check (search "M12-AUTHORITY-PRINT-PROBE"
                                  (getf result :value)
                                  :test #'char-equal)
                          "mailbox carries the inert bounded representation")
                   (check (null (slot-value print-agent
                                            'anuna-imago::tools))
                          "print callback mutation is sanitized before return")
                   (check (null
                           (gethash
                            "tools"
                            (build-request
                             (make-anthropic-provider :api-key "test")
                             "print callback advertisement probe"
                             print-agent)))
                          "print callback cannot alter later advertisement")
                   (check
                    (let ((*current-agent* print-agent))
                      (handler-case
                          (progn (dispatch-tool! name nil) nil)
                        (anuna-imago::unauthorized-tool-call () t)))
                    "print callback cannot alter ordinary dispatch"))

                 ;; Trusted reductions remain reductions after subsequent
                 ;; evaluations; cleanup does not restore removed authority.
                 (let* ((shrink-agent
                          (make-instance 'agent
                                         :id 'm12-shrinking-authority-agent
                                         :capability "authority:shrink-test"
                                         :tools (list alias-allowed-name name)))
                        (*current-agent* shrink-agent)
                        (pin-result
                          (anuna-imago::%harness-eval-handler
                           (list :form "(+ 1 1)"))))
                   (check (eq :ok (getf pin-result :status))
                          "first evaluation pins the initial ceiling")
                   (setf (agent-tools shrink-agent)
                         (list alias-allowed-name))
                   (let ((later-result
                           (anuna-imago::%harness-eval-handler
                            (list :form "(+ 2 2)"))))
                     (check (eq :ok (getf later-result :status))
                            "evaluation remains usable after a trusted shrink"))
                   (check (equal (list alias-allowed-name)
                                 (agent-tools shrink-agent))
                          "legitimate authority reduction persists"))

                 ;; Delayed provider and request-builder methods are named TCB
                 ;; links. Even if the raw slot changes after evaluation, its
                 ;; persistent reader ceiling governs advertisement and drive.
                 (let* ((provider-gf (fdefinition 'provider-stream!))
                        (provider-specializers
                          (list (find-class 'provider)
                                (find-class 'agent)
                                (find-class t)))
                        (provider-original
                          (find-method provider-gf '(:around)
                                       provider-specializers nil))
                        (build-gf (fdefinition 'build-request))
                        (build-specializers
                          (list (find-class 'provider)
                                (find-class t)
                                (find-class 'agent)))
                        (build-original
                          (find-method build-gf '(:around)
                                       build-specializers nil))
                        (delayed-agent
                          (make-instance
                           'agent
                           :id 'm12-delayed-provider-agent
                           :capability "authority:delayed-provider"
                           :tools (list alias-allowed-name)
                           :provider
                           (make-stub-provider
                            :responder
                            (lambda (message)
                              (declare (ignore message))
                              (list (list :tool-use "delayed-provider"
                                          name nil))))))
                        (*current-agent* delayed-agent)
                        (pin-result
                          (anuna-imago::%harness-eval-handler
                           (list :form "(+ 8 9)")))
                        (provider-method-result nil)
                        (build-method-result nil)
                        (request nil)
                        (reply nil))
                   (unwind-protect
                        (progn
                          (setf provider-method-result
                                (anuna-imago::%harness-eval-handler
                                 (list
                                  :form
                                  "(progn (defmethod anuna-imago:provider-stream! :around ((provider anuna-imago:provider) (agent anuna-imago:agent) message) (declare (ignore message)) (setf (anuna-imago:agent-tools agent) '(anuna-imago.test::m12-operator-authority-hidden)) (call-next-method)))")))
                          (setf build-method-result
                                (anuna-imago::%harness-eval-handler
                                 (list
                                  :form
                                  "(progn (defmethod anuna-imago:build-request :around ((provider anuna-imago:provider) message (agent anuna-imago:agent)) (declare (ignore provider message agent)) (let ((request (make-hash-table :test 'equal))) (setf (gethash \"tools\" request) (vector \"forged-hidden\")) request)))")))
                          ;; Model a delayed callback changing the physical slot.
                          (setf (slot-value delayed-agent 'anuna-imago::tools)
                                (list name))
                          (setf request
                                (build-request
                                 (make-anthropic-provider :api-key "test")
                                 "delayed advertisement probe"
                                 delayed-agent)
                                reply (drive-stream delayed-agent "delayed")))
                     (let ((current
                             (find-method provider-gf '(:around)
                                          provider-specializers nil)))
                       (unless (eq current provider-original)
                         (when current (remove-method provider-gf current))
                         (when provider-original
                           (add-method provider-gf provider-original))))
                     (let ((current
                             (find-method build-gf '(:around)
                                          build-specializers nil)))
                       (unless (eq current build-original)
                         (when current (remove-method build-gf current))
                         (when build-original
                           (add-method build-gf build-original)))))
                   (check (eq :ok (getf pin-result :status))
                          "delayed-provider agent pins its first ceiling")
                   (check (eq :vetoed (getf provider-method-result :status))
                          "delayed PROVIDER-STREAM! method is vetoed")
                   (check (eq :vetoed (getf build-method-result :status))
                          "direct BUILD-REQUEST method is vetoed")
                   (check (null (gethash "tools" request))
                          "persistent ceiling omits delayed advertisement")
                   (check
                    (eq :unauthorized
                        (getf (first (getf reply :tool-results)) :status))
                    "ordinary delayed provider dispatch remains unauthorized"))

                 ;; Enforcement helpers are themselves part of the TCB.  If
                 ;; the first form can redefine this predicate, the second
                 ;; forbidden form disappears from the fact-aware reasoner.
                 (let ((target 'anuna-imago::safety-layer-symbol-p)
                       (original
                         (symbol-function
                          'anuna-imago::safety-layer-symbol-p))
                       (redefinition-result nil)
                       (followup-result nil))
                   (unwind-protect
                        (progn
                          (setf redefinition-result
                                (anuna-imago::%harness-eval-handler
                                 (list
                                  :form
                                  "(progn (defun anuna-imago::safety-layer-symbol-p (symbol) (declare (ignore symbol)) nil))")))
                          (setf followup-result
                                (anuna-imago::%harness-eval-handler
                                 (list
                                  :form
                                  (format nil
                                          "(let ((anuna-imago:*current-agent* nil) (anuna-imago::*operator-tool-dispatch-p* t)) ~A)"
                                          (%m12-operator-authority-frame
                                           "post-tcb-redefinition")))))
                     (setf (symbol-function target) original))
                   (check (eq :vetoed (getf redefinition-result :status))
                          "enforcement-helper redefinition is vetoed")
                   (check (eq :vetoed (getf followup-result :status))
                          "subsequent forbidden form remains denied")))

                 ;; Structural SETF protection covers named TCB function
                 ;; cells, and a later computed dispatch observes the original.
                 (let* ((target 'anuna-imago::%authorized-agent-tool-name)
                        (original (symbol-function target))
                        (replacement-result nil)
                        (followup-result nil))
                   (unwind-protect
                        (progn
                          (setf replacement-result
                                (anuna-imago::%harness-eval-handler
                                 (list
                                  :form
                                  "(setf (symbol-function 'anuna-imago::%authorized-agent-tool-name) (lambda (name) (values name t)))")))
                          (setf followup-result
                                (anuna-imago::%harness-eval-handler
                                 (list
                                  :form
                                  "(funcall (symbol-function (find-symbol \"DISPATCH-TOOL!\" \"ANUNA-IMAGO\")) (find-symbol \"M12-OPERATOR-AUTHORITY-HIDDEN\" \"ANUNA-IMAGO.TEST\") nil)"))))
                     (setf (symbol-function target) original))
                   (check (eq :rejected (getf replacement-result :status))
                          "SETF cannot replace a named authorization-TCB cell")
                   (check (eq :error (getf followup-result :status))
                          "authorization remains restrictive after rejected SETF"))

                 ;; Exercise one named link from every authorization-TCB
                 ;; responsibility.  Each rejected replacement is followed by
                 ;; a fresh malformed-proof probe to establish sequential
                 ;; fail-closed behavior, not merely set membership.
                 (dolist (target
                          '(anuna-imago::%authorized-agent-tool-name
                            anuna-imago::%effective-agent-tool-names
                            anuna-imago::%after-prefilter-pipeline
                            anuna-imago::%lift-form
                            anuna-imago::query
                            anuna-imago::%proof-result-valid-p
                            anuna-imago::%eval-form-with-timeout
                            anuna-imago::%tool-receipt!
                            anuna-imago::receive!
                            anuna-imago::%ht
                            anuna-imago::%hash->plist
                            anuna-imago::%anthropic-response->frames
                            anuna-imago::%openrouter-response->frames
                            com.inuoe.jzon:parse
                            print-object
                            anuna-imago::provider-stream!
                            anuna-imago::build-request
                            anuna-imago::install-self-modification-tools!))
                   (setf *m12-reasoner-protected-calls* 0)
                   (let* ((replacement-result
                            (anuna-imago::%harness-eval-handler
                             (list
                              :form
                              (format nil
                                      "(progn (defun ~S (&rest args) (declare (ignore args)) nil))"
                                      target))))
                          (probe-result
                            (let ((anuna-imago::*reasoner-ipc-call*
                                    (lambda (op &rest args)
                                      (declare (ignore args))
                                      (case op
                                        ((:assert-fact :retract-fact) :ok)
                                        (:query
                                         '(:tag :-delta :derivation nil))
                                        (otherwise :ok))))
                                  (anuna-imago::*active-theory-handle*
                                    :m12-malformed-proof-after-tcb))
                              (anuna-imago::%harness-eval-handler
                               (list
                                :form
                                "(anuna-imago.test::m12-reasoner-protected-probe)")))))
                     (check (eq :vetoed (getf replacement-result :status))
                            (format nil "named TCB replacement is vetoed: ~S"
                                    target))
                     (check (some (lambda (clause)
                                    (and (consp clause)
                                         (member target clause :test #'eq)))
                                  (getf replacement-result :derivation))
                            (format nil "TCB veto identifies target: ~S" target))
                     (check (eq :vetoed (getf probe-result :status))
                            (format nil
                                    "malformed proof still denies after ~S"
                                    target))
                     (check (zerop *m12-reasoner-protected-calls*)
                            "sequential malformed-proof probe stays inert")))

                 (dolist (form
                          '("(progn (defclass anuna-imago:agent () ()))"
                            "(progn (defstruct anuna-imago:tool))"))
                   (let ((result
                           (anuna-imago::%harness-eval-handler
                            (list :form form))))
                     (check (eq :vetoed (getf result :status))
                            "class/structure regeneration is vetoed")))

                 ;; The audit writer calls the generated RECEIPT-LOG stream
                 ;; accessor directly. A delayed method replacement could hide
                 ;; a later receipt while returning a plausible handler result.
                 (let* ((gf
                          (fdefinition 'anuna-imago::%receipt-log-stream))
                        (specializers
                          (list (find-class 'anuna-imago:receipt-log)))
                        (original-method
                          (find-method gf nil specializers nil))
                        (method-result nil))
                   (unwind-protect
                        (setf method-result
                              (anuna-imago::%harness-eval-handler
                               (list
                                :form
                                "(progn (defmethod anuna-imago::%receipt-log-stream ((log anuna-imago:receipt-log)) (declare (ignore log)) nil))")))
                     (let ((current (find-method gf nil specializers nil)))
                       (unless (eq current original-method)
                         (when current (remove-method gf current))
                         (when original-method
                           (add-method gf original-method)))))
                   (check (eq :vetoed (getf method-result :status))
                          "RECEIPT-LOG stream method override is vetoed")
                   (check (some (lambda (clause)
                                  (and (consp clause)
                                       (member
                                        'anuna-imago::%receipt-log-stream
                                        clause :test #'eq)))
                                (getf method-result :derivation))
                          "receipt stream veto carries safety derivation"))

                 ;; The generated AGENT-TOOLS reader is a generic function.
                 ;; Replacing its AGENT method would poison the next worker's
                 ;; snapshot before EVAL begins, so protect it across calls.
                 (let* ((gf (fdefinition 'anuna-imago:agent-tools))
                        (specializers (list (find-class 'anuna-imago:agent)))
                        (original-method
                          (find-method gf nil specializers nil))
                        (control-result
                          (anuna-imago::%harness-eval-handler
                           (list :form "(+ 20 22)")))
                        (method-result nil)
                        (dispatch-result nil)
                        (observed-tools nil))
                   (unwind-protect
                        (progn
                          (setf method-result
                                (anuna-imago::%harness-eval-handler
                                 (list
                                  :form
                                  "(progn (defmethod anuna-imago:agent-tools ((agent anuna-imago:agent)) (declare (ignore agent)) '(anuna-imago.test::m12-operator-authority-hidden)))")))
                          (setf observed-tools (agent-tools agent))
                          (setf dispatch-result
                                (anuna-imago::%harness-eval-handler
                                 (list
                                  :form
                                  "(funcall (symbol-function (find-symbol \"DISPATCH-TOOL!\" \"ANUNA-IMAGO\")) (find-symbol \"M12-OPERATOR-AUTHORITY-HIDDEN\" \"ANUNA-IMAGO.TEST\") nil)")))
                     (let ((current (find-method gf nil specializers nil)))
                       (unless (eq current original-method)
                         (when current (remove-method gf current))
                         (when original-method (add-method gf original-method)))))
                   (check (eq :ok (getf control-result :status))
                          "fact-aware authority context accepts a harmless control")
                   (check (eq :vetoed (getf method-result :status))
                          "AGENT-TOOLS method override is vetoed")
                   (check (some (lambda (clause)
                                  (and (consp clause)
                                       (member 'anuna-imago:agent-tools clause
                                               :test #'eq)))
                                (getf method-result :derivation))
                          "AGENT-TOOLS veto carries explicit safety derivation")
                   (check (equal (list alias-allowed-name) observed-tools)
                          "originating agent keeps its original allowlist")
                   (check (eq :error (getf dispatch-result :status))
                          "next evaluation snapshot remains restrictive"))
             ))))

           ;; A nested installer cannot widen an already active ceiling.
           (anuna-imago::%call-with-evaluation-tool-authority
            agent
            (list alias-allowed-name)
            (lambda ()
              (anuna-imago::%call-with-evaluation-tool-authority
               agent
               (list name)
               (lambda ()
                 (multiple-value-bind (permitted-p active-p)
                     (anuna-imago::%evaluation-tool-permitted-p name)
                   (check active-p "evaluation authority ceiling stays active")
                   (check (not permitted-p)
                          "nested installer cannot widen the ceiling"))))))

           (let* ((required
                    '(anuna-imago::*authorization-tcb-symbols*
                      anuna-imago::*safety-layer-symbols*
                      anuna-imago::*safety-layer-categories*
                      anuna-imago::safety-layer-symbol-p
                      anuna-imago::%harness-eval-prefilter
                      anuna-imago::%prefilter-setf
                      anuna-imago::%lift-form
                      anuna-imago::%lift-facts
                      anuna-imago::%assert-lift-facts!
                      anuna-imago::%retract-lift-facts!
                      anuna-imago::%query-forbidden
                      anuna-imago::%proof-result-valid-p
                      anuna-imago::proof-result-positive-p
                      anuna-imago::query
                      anuna-imago::assert-fact!
                      anuna-imago::retract-fact!
                      anuna-imago::%proper-list-p
                      anuna-imago::%eval-form-with-timeout
                      anuna-imago::%harness-eval-handler
                      anuna-imago::%after-parse-pipeline
                      anuna-imago::%after-prefilter-pipeline
                      anuna-imago::%after-reasoner-pipeline
                      anuna-imago::%normalize-tool-name
                      anuna-imago::%tool-name-equal-p
                      anuna-imago::%canonical-evaluation-tool-names
                      anuna-imago::%evaluation-authority-thread-key
                      anuna-imago::%call-with-evaluation-tool-authority
                      anuna-imago::%evaluation-tool-permitted-p
                      anuna-imago::%effective-agent-tool-names
                      anuna-imago::%authorized-agent-tool-name
                      anuna-imago:agent
                      anuna-imago:agent-tools
                      anuna-imago:tool
                      sb-thread:*current-thread*
                      anuna-imago:dispatch-tool!
                      anuna-imago:process-turn
                      anuna-imago::%dispatch-tool-use
                      anuna-imago:drive-stream
                      anuna-imago::handle-tool-frame
                      anuna-imago:provider-stream!
                      anuna-imago:stream-next-frame!
                      anuna-imago:tool-results-message-content
                      anuna-imago:build-request
                      anuna-imago::%ht
                      anuna-imago::%hash->plist
                      anuna-imago::%tool->anthropic-ht
                      anuna-imago::%tool->openai-ht
                      anuna-imago:tool->anthropic-descriptor
                      anuna-imago::*anthropic-http-post*
                      anuna-imago::%anthropic-stop-reason-keyword
                      anuna-imago::%anthropic-response->frames
                      anuna-imago::%fetch-and-parse
                      anuna-imago::*openrouter-http-post*
                      anuna-imago::+openrouter-maximum-response-octets+
                      anuna-imago::+openrouter-maximum-argument-octets+
                      anuna-imago::+openrouter-maximum-json-depth+
                      anuna-imago::+openrouter-maximum-json-nodes+
                      anuna-imago::+openrouter-maximum-object-keys+
                      anuna-imago::+openrouter-maximum-array-elements+
                      anuna-imago::+openrouter-maximum-string-characters+
                      anuna-imago::+openrouter-maximum-tool-calls+
                      anuna-imago::+openrouter-maximum-identifier-characters+
                      anuna-imago::+openrouter-maximum-tool-name-characters+
                      anuna-imago::%openrouter-json-octet-length
                      anuna-imago::%openrouter-scan-json!
                      anuna-imago::%openrouter-parse-json
                      anuna-imago::%openrouter-hash-shape!
                      anuna-imago::%openrouter-token-string-p
                      anuna-imago::%openrouter-registered-tool
                      anuna-imago::%openrouter-argument-type-p
                      anuna-imago::%openrouter-recognize-tool-arguments
                      anuna-imago::%openai-args->plist
                      anuna-imago::%openrouter-finish-reason
                      anuna-imago::%openrouter-validate-token-details!
                      anuna-imago::%openrouter-validate-usage!
                      anuna-imago::%openrouter-validate-root-metadata!
                      anuna-imago::%openrouter-error-frames
                      anuna-imago::%openrouter-error-envelope-frames
                      anuna-imago::%openrouter-tool-call->frame
                      anuna-imago::%openrouter-response->frames
                      anuna-imago::%openrouter-bounded-response-string
                      anuna-imago::%openrouter-fetch-and-parse
                      com.inuoe.jzon:parse
                      com.inuoe.jzon:parse-next
                      com.inuoe.jzon:with-parser
                      com.inuoe.jzon:make-parser
                      com.inuoe.jzon:close-parser
                      com.inuoe.jzon:stringify
                      anuna-imago::%ensure-jzon-package-locked!
                      sb-ext:lock-package
                      sb-ext:package-locked-p
                      sb-ext:unlock-package
                      sb-ext:without-package-locks
                      anuna-imago:receipt-log
                      anuna-imago:receipt-log-path
                      anuna-imago::%receipt-log-stream
                      anuna-imago::%receipt-log-seqs
                      anuna-imago::%receipt-log-lock
                      anuna-imago:iso-8601-now
                      anuna-imago:mailbox
                      anuna-imago:make-mailbox
                      anuna-imago:send!
                      anuna-imago:receive!
                      anuna-imago::mailbox-head
                      anuna-imago::mailbox-tail
                      anuna-imago::mailbox-count
                      anuna-imago::mailbox-closed
                      anuna-imago::mailbox-lock
                      anuna-imago::mailbox-cv
                      print-object))
                  (missing
                    (remove-if #'anuna-imago::safety-layer-symbol-p required))
                  (category
                    (assoc :authorization-tcb
                           anuna-imago::*safety-layer-categories*)))
             (check (null missing)
                    (format nil "named authorization TCB is complete; missing ~S"
                            missing))
             (check (null (set-difference
                           anuna-imago::*authorization-tcb-symbols*
                           (second category)
                           :test #'eq))
                    "the authorization-TCB category covers its full set"))

           (check (zerop *m12-operator-authority-hidden-calls*)
                  "no evaluated authority attempt reaches the hidden handler")
           (let ((*current-agent* nil))
             (check (eq :hidden-ran
                        (with-operator-tool-dispatch
                          (dispatch-tool! name nil)))
                    "the explicit external operator scope remains usable"))
           (check (= 1 *m12-operator-authority-hidden-calls*)
                  "only the external operator call reaches the hidden handler"))
      (when (macro-function escape-macro)
        (fmakunbound escape-macro))
      (when (macro-function thread-escape-macro)
        (fmakunbound thread-escape-macro))
      (setf *m12-authority-decoy-thread* nil)
      (when decoy-thread
        (sb-thread:signal-semaphore decoy-stop)
        (sb-thread:join-thread decoy-thread))
      (if alias-allowed-prior
          (register-tool! alias-allowed-prior)
          (unregister-tool! alias-allowed-name))
      (if alias-hidden-prior
          (register-tool! alias-hidden-prior)
          (unregister-tool! alias-hidden-name))
      (if prior
          (register-tool! prior)
          (unregister-tool! name)))))

(defun %exercise-m12-reasoner-failure (query-result-thunk test-id)
  "Run harness-eval with a failing or malformed reasoner response."
  (setf *m12-reasoner-protected-calls* 0)
  (let ((anuna-imago::*reasoner-ipc-call*
          (lambda (op &rest args)
            (declare (ignore args))
            (case op
              (:query (funcall query-result-thunk))
              ((:assert-fact :retract-fact) :ok)
              (otherwise :spec-014-red-gate))))
        (anuna-imago::*active-theory-handle* :spec-014-red-gate)
        (anuna-imago::*harness-eval-audit-log* nil))
    (let ((res
            (anuna-imago::%harness-eval-handler
             '(:form "(anuna-imago.test::m12-reasoner-protected-probe)"))))
      (check (eq :vetoed (getf res :status))
             (format nil "~A vetoes harness-eval" test-id))
      (check (eq :reasoner (getf res :phase))
             (format nil "~A is attributed to the reasoner phase" test-id))
      (check (zerop *m12-reasoner-protected-calls*)
             (format nil "~A never evaluates the protected form" test-id)))))

(defun test-m12-handler-fails-closed-on-reasoner-error ()
  "SPEC-014 TEST-004: reasoner transport failure cannot reach EVAL."
  (format t "~%-- m12-handler-fails-closed-on-reasoner-error (SPEC-014 TEST-004) --~%")
  (%exercise-m12-reasoner-failure
   (lambda () (error "simulated reasoner outage"))
   "query error"))

(defun test-m12-handler-fails-closed-on-fact-seam-errors ()
  "SPEC-014 TEST-054: assertion and retraction failures cannot reach EVAL."
  (format t "~%-- m12-handler-fails-closed-on-fact-seam-errors (SPEC-014 TEST-054) --~%")
  (dolist (failing-op '(:assert-fact :retract-fact))
    (setf *m12-reasoner-protected-calls* 0)
    (let ((anuna-imago::*reasoner-ipc-call*
            (lambda (op &rest args)
              (declare (ignore args))
              (cond
                ((eq op failing-op)
                 (error "simulated ~S failure" failing-op))
                ((eq op :query)
                 '(:tag :-delta :derivation nil :time-ms 1))
                (t :ok))))
          (anuna-imago::*active-theory-handle* :spec-014-fact-red-gate)
          (anuna-imago::*harness-eval-audit-log* nil))
      (let ((res
              (anuna-imago::%harness-eval-handler
               '(:form
                 "(anuna-imago.test::m12-reasoner-protected-probe)"))))
        (check (eq :vetoed (getf res :status))
               (format nil "~S failure vetoes harness-eval" failing-op))
        (check (eq :reasoner (getf res :phase))
               (format nil "~S failure is attributed to reasoner" failing-op))
        (check (zerop *m12-reasoner-protected-calls*)
               (format nil "~S failure cannot execute the form" failing-op))))))

(defun test-m12-handler-fails-closed-on-malformed-reasoner-evidence ()
  "SPEC-014 TEST-025: every malformed proof-result class cannot reach EVAL."
  (format t "~%-- m12-handler-fails-closed-on-malformed-reasoner-evidence (SPEC-014 TEST-025) --~%")
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
      (%exercise-m12-reasoner-failure
       (lambda () evidence)
       description))))

(defun test-m12-handler-error-during-eval ()
  (format t "~%-- m12-handler-error-during-eval (TEST-003c) --~%")
  (with-m12-handler-fixture ()
    (let ((res (anuna-imago::%harness-eval-handler
                '(:form "(error \"boom\")"))))
      (check (eq :error      (getf res :status)))
      (check (eq :evaluation (getf res :phase)))
      (check (search "boom" (getf res :message))))))

(defun test-m12-handler-receipt-on-every-phase ()
  (format t "~%-- m12-handler-receipt-every-phase (TEST-004) --~%")
  (let ((path (format nil "/tmp/imago-m12-receipts-~D.log" (random 100000))))
    (let ((anuna-imago::*reasoner-ipc-call* #'%m12-stub-reasoner)
          (anuna-imago::*active-theory-handle* :m12-stub-handle)
          (anuna-imago::*harness-eval-audit-log* (open-receipt-log path)))
      (unwind-protect
           (progn
             (setf anuna-imago::*form-counter* 0)
             ;; pre-filter rejection
             (anuna-imago::%harness-eval-handler '(:form "(unintern 'x)"))
             ;; reasoner veto
             (let ((*m12-stub-veto-set* (list :form-1)))
               (anuna-imago::%harness-eval-handler '(:form "(defun n () 1)")))
             ;; eval error
             (anuna-imago::%harness-eval-handler '(:form "(error \"boom\")"))
             ;; ok
             (anuna-imago::%harness-eval-handler '(:form "(+ 2 3)"))
             ;; (force flush, file is closed in unwind-protect)
             nil)
        (close-receipt-log! anuna-imago::*harness-eval-audit-log*)))
    (let ((entries (read-receipts path)))
      (check (= 4 (length entries)) "exactly four receipt entries")
      (let ((phases (mapcar (lambda (e) (getf e :result-phase)) entries))
            (tags   (mapcar (lambda (e) (getf e :result-tag))   entries)))
        (check (member :pre-filter phases))
        (check (member :reasoner   phases))
        (check (member :evaluation phases))
        (check (member :evaluated  phases))
        (check (member :rejected   tags))
        (check (member :vetoed     tags))
        (check (member :error      tags))
        (check (member :ok         tags))))
    (handler-case (delete-file path) (error () nil))))

;; =========================================================================
;; t09 — install function (REQ-001)
;; =========================================================================

(defun test-m12-install-fn-registers-tool ()
  (format t "~%-- m12-install-fn-registers-tool (REQ-001/REQ-009) --~%")
  ;; Load the install fn (it's not part of the system, must be loaded
  ;; explicitly). It might already be loaded from a prior test run.
  (unless (fboundp 'anuna-imago::install-self-modification-tools!)
    (load (merge-pathnames "examples/self-modifying.lisp"
                            (asdf:system-source-directory :imago))))
  ;; Ensure clean state: nothing registered, no theory
  (unregister-tool! 'anuna-imago::harness-eval)
  (let ((anuna-imago::*active-theory-handle* nil))
    (check (eq :no-active-theory
               (anuna-imago::install-self-modification-tools!))
           "refuses to install without a theory"))
  ;; Now provide a theory and install
  (let ((anuna-imago::*active-theory-handle* :stub-theory)
        (anuna-imago::*reasoner-ipc-call* #'%m12-stub-reasoner)
        (path (format nil "/tmp/imago-m12-install-~D.log" (random 100000))))
    (check (eq :ok (anuna-imago::install-self-modification-tools!
                    :audit-log-path path)))
    (check (sb-ext:package-locked-p (find-package :com.inuoe.jzon))
           "install locks the transitive Jzon parser implementation")
    (check (find-tool 'anuna-imago::harness-eval) "harness-eval registered")
    (check (eq :eval (tool-permission (find-tool 'anuna-imago::harness-eval))))
    (check (member :eval *valid-permissions*))
    (check (find-package :anuna-imago-user))
    ;; All six tools registered (harness-eval + 5 introspection)
    (check (find-tool 'anuna-imago::harness-list-safety-layer))
    (check (find-tool 'anuna-imago::harness-redefine-history))
    (check (find-tool 'anuna-imago::harness-list-rollbacks))
    (check (find-tool 'anuna-imago::harness-rollback))
    (check (find-tool 'anuna-imago::harness-query-self-mod-receipts))
    ;; Idempotence
    (check (eq :already-installed
               (anuna-imago::install-self-modification-tools!
                :audit-log-path path)))
    ;; Uninstall removes all six
    (check (eq :ok (anuna-imago::uninstall-self-modification-tools!)))
    (check (null (find-tool 'anuna-imago::harness-eval)))
    (check (null (find-tool 'anuna-imago::harness-list-safety-layer)))
    (check (null (find-tool 'anuna-imago::harness-rollback)))))

(defun test-m12-install-fails-closed-on-safety-fact-error ()
  "SPEC-014 TEST-055: failed safety-fact setup cannot expose harness-eval."
  (format t "~%-- m12-install-fails-closed-on-safety-fact-error (SPEC-014 TEST-055) --~%")
  (unless (fboundp 'anuna-imago::install-self-modification-tools!)
    (load (merge-pathnames "examples/self-modifying.lisp"
                           (asdf:system-source-directory :imago))))
  (when (find-tool 'anuna-imago::harness-eval)
    (anuna-imago::uninstall-self-modification-tools!))
  (let ((anuna-imago::*active-theory-handle* :failed-safety-setup)
        (anuna-imago::*reasoner-ipc-call*
          (lambda (op &rest args)
            (declare (ignore args))
            (if (eq op :assert-fact)
                (error "simulated safety-fact assertion failure")
                :ok)))
        (path (format nil "/tmp/imago-m12-failed-install-~D.log"
                      (random 100000))))
    (unwind-protect
         (progn
           (check (handler-case
                      (progn
                        (anuna-imago::install-self-modification-tools!
                         :audit-log-path path)
                        nil)
                    (error () t))
                  "safety-fact assertion failure aborts installation")
           (check (null (find-tool 'anuna-imago::harness-eval))
                  "failed safety setup does not register harness-eval")
           (check (not (member :eval *valid-permissions*))
                  "failed safety setup does not enable eval permission"))
      (when (find-tool 'anuna-imago::harness-eval)
        (anuna-imago::uninstall-self-modification-tools!)))))

;; =========================================================================
;; Introspection tools
;; =========================================================================

(defun test-m12-tool-list-safety-layer ()
  (format t "~%-- m12-tool-list-safety-layer --~%")
  ;; Reach the handler directly via dispatch (no full install needed)
  (let ((handler (symbol-function 'anuna-imago::%tool-list-safety-layer)))
    (let ((all (funcall handler nil)))
      (check (consp all))
      (check (every #'stringp all))
      (check (some (lambda (s) (search "register-tool" s :test #'char-equal)) all)
             "register-tool! is in the safety set"))
    (let ((eval-only (funcall handler '(:prefix "EVAL"))))
      (check (every (lambda (s) (search ":EVAL" s :test #'char-equal))
                    eval-only)
             "prefix filter narrows the set"))))

(defun test-m12-tool-redefine-history-summary ()
  (format t "~%-- m12-tool-redefine-history-summary --~%")
  (clrhash *redefine-history*)
  (anuna-imago::%record-definition! 'anuna-imago.test::demo-x "(defun demo-x () 1)" 'agent nil nil)
  (anuna-imago::%record-definition! 'anuna-imago.test::demo-y "(defun demo-y () 2)" 'agent nil nil)
  (let* ((handler (symbol-function 'anuna-imago::%tool-redefine-history))
         (summary (funcall handler nil)))
    (check (= 2 (length summary)) "two redefined symbols")
    (check (every (lambda (e) (and (getf e :symbol)
                                    (integerp (getf e :event-count))))
                  summary))))

(defun test-m12-tool-list-rollbacks-and-rollback ()
  (format t "~%-- m12-tool-list-rollbacks-and-rollback --~%")
  (setf (fill-pointer *rollback-register*) 0)
  (anuna-imago::%push-function-rollback!
   'anuna-imago.test::demo-fn
   (lambda () :original)
   t 'agent "form-hash")
  (let* ((list-h (symbol-function 'anuna-imago::%tool-list-rollbacks))
         (records (funcall list-h nil)))
    (check (= 1 (length records)))
    (let ((r (first records)))
      (check (= 0 (getf r :index)))
      (check (eq :function (getf r :kind)))
      (check (string= "DEMO-FN" (getf r :symbol)))
      (check (null (getf r :rolled-back)))))
  (let* ((rollback-h (symbol-function 'anuna-imago::%tool-rollback))
         (bad (funcall rollback-h '(:index "not-an-int"))))
    (check (eq :invalid-index (getf bad :error))
           "rollback! tool rejects non-integer :index"))
  (let* ((rollback-h (symbol-function 'anuna-imago::%tool-rollback))
         (good (funcall rollback-h '(:index 0))))
    (check (eq :ok (getf good :status)))
    (check (= 0 (getf good :index)))))

(defun test-m12-tool-query-self-mod-receipts ()
  (format t "~%-- m12-tool-query-self-mod-receipts --~%")
  (let* ((handler (symbol-function 'anuna-imago::%tool-query-self-mod-receipts))
         ;; Without audit log:
         (none (let ((anuna-imago::*harness-eval-audit-log* nil))
                 (funcall handler nil))))
    (check (eq :no-audit-log (getf none :error))))
  ;; With audit log + an entry
  (let ((path (format nil "/tmp/imago-m12-introspect-~D.log" (random 100000))))
    (let ((anuna-imago::*harness-eval-audit-log* (open-receipt-log path)))
      (unwind-protect
           (progn
             (anuna-imago::%tool-receipt!
              anuna-imago::*harness-eval-audit-log*
              :tool 'harness-eval :agent-id 'demo
              :form "(+ 1 2)" :result-phase :evaluated :result-tag :ok
              :elapsed-ms 1 :result-summary nil)
             (close-receipt-log! anuna-imago::*harness-eval-audit-log*)
             ;; Re-open so the introspection tool can read
             (setf anuna-imago::*harness-eval-audit-log* (open-receipt-log path))
             (let* ((handler (symbol-function 'anuna-imago::%tool-query-self-mod-receipts))
                    (entries (funcall handler '(:limit 5))))
               (check (consp entries))
               (check (string= "(+ 1 2)" (getf (first entries) :form)))
               (check (eq :ok (getf (first entries) :result-tag)))))
        (handler-case (close-receipt-log! anuna-imago::*harness-eval-audit-log*) (error () nil))
        (handler-case (delete-file path) (error () nil))))))

;; =========================================================================
;; REQ-011 / TEST-016 — persistence across save-image!
;; =========================================================================
;;
;; SAVE-IMAGE! does not return, so (as in m9-tests) a sub-SBCL performs the
;; save: it loads :imago, loads examples/self-modifying.lisp, installs the
;; port with a stubbed reasoner, populates the origin index and rollback
;; register, then saves an image whose toplevel prints the survival state
;; of the four artefacts as a plist. The parent boots the binary and checks.

(defvar *m12-image-path* "/tmp/imago-m12-persist-agent")

(defun test-m12-persistence-across-save ()
  (format t "~%-- m12-persistence-across-save (TEST-016) --~%")
  (handler-case (delete-file *m12-image-path*) (error () nil))
  (let ((root   (namestring (asdf:system-source-directory :imago)))
        (ql     (namestring (merge-pathnames "quicklisp/setup.lisp"
                                             (user-homedir-pathname))))
        (script (format nil "/tmp/imago-m12-persist-save-~D.lisp" (random 100000))))
    (with-open-file (s script :direction :output :if-exists :supersede)
      (write-string "(in-package :anuna-imago)" s) (terpri s)
      (format s "(load \"~Aexamples/self-modifying.lisp\")~%" root)
      (write-string "(setf *reasoner-ipc-call*
        (lambda (&rest args) (declare (ignore args))
          (list :tag :-delta :derivation nil :time-ms 1)))
      (setf *active-theory-handle* :m12-persist-stub)
      (install-self-modification-tools!
       :audit-log-path \"/tmp/imago-m12-persist-audit.log\")
      (%record-definition! 'anuna-imago-user::persisted-fn
                           \"(defun persisted-fn () 1)\" 'm12-test nil nil)
      (%push-function-rollback! 'anuna-imago-user::persisted-fn
                                (lambda () 1) t 'm12-test \"form-hash\")
      (defun m12-persist-report ()
        (prin1 (list :tool      (and (find-tool 'harness-eval) t)
                     :theory    (and *active-theory-handle* t)
                     :history   (hash-table-count *redefine-history*)
                     :rollbacks (length *rollback-register*)))
        (terpri)
        (sb-ext:exit :code 0))" s) (terpri s)
      (format s "(save-image! \"~A\" :toplevel 'm12-persist-report)~%"
              *m12-image-path*))
    (multiple-value-bind (out err code)
        (uiop:run-program
         (list "sbcl" "--non-interactive" "--no-userinit" "--no-sysinit"
               "--load" ql
               "--eval" (format nil "(push (truename \"~A\") asdf:*central-registry*)" root)
               "--eval" "(asdf:load-system :imago)"
               "--load" script)
         :ignore-error-status t :output :string :error-output :string)
      (declare (ignore out))
      (check (zerop code)
             (format nil "sub-SBCL save succeeds (stderr: ~A)"
                     (subseq err 0 (min 120 (length err)))))
      (check (probe-file *m12-image-path*) "saved binary exists"))
    (multiple-value-bind (out err code)
        (uiop:run-program (list *m12-image-path*)
                          :ignore-error-status t
                          :output :string :error-output :string)
      (declare (ignore err))
      (check (zerop code) "saved image boots and exits 0")
      (let ((report (handler-case
                        (read-from-string out nil nil
                                          :start (or (position #\( out) 0))
                      (error () nil))))
        (check (consp report) "toplevel prints a readable report plist")
        (check (eq t (getf report :tool))
               "harness-eval tool survives in the registry")
        (check (eq t (getf report :theory))
               "active theory handle survives")
        (check (plusp (getf report :history 0))
               "*redefine-history* survives populated")
        (check (plusp (getf report :rollbacks 0))
               "*rollback-register* survives populated")))
    (handler-case (delete-file *m12-image-path*) (error () nil))
    (handler-case (delete-file script) (error () nil))))

;; =========================================================================
;; REQ-009 / TEST-010 — :eval permission honoured by policy denial
;; =========================================================================

(defun test-m12-eval-permission-policy-denial ()
  (format t "~%-- m12-eval-permission-policy-denial (TEST-010) --~%")
  ;; A permission policy is an :on-tool-call hook that vetoes frames whose
  ;; tool carries :eval permission. The vetoed call must never reach the
  ;; pre-filter/handler — verified by an empty receipt log.
  (let ((path (format nil "/tmp/imago-m12-policy-~D.log" (random 100000)))
        (handle nil))
    (let ((anuna-imago::*harness-eval-audit-log* (open-receipt-log path)))
      (unwind-protect
           (progn
             (setf handle
                   (register-hook
                    :on-tool-call
                    (lambda (agent frame)
                      (declare (ignore agent))
                      (let ((tool (find-tool (getf frame :name))))
                        (if (and tool (eq :eval (tool-permission tool)))
                            :veto
                            frame)))))
             ;; Register a stand-in harness-eval carrying :eval permission.
             (let ((*valid-permissions* (cons :eval *valid-permissions*)))
               (register-tool!
                (make-tool :name 'anuna-imago::harness-eval
                           :description "stand-in" :permission :eval
                           :schema nil
                           :handler (lambda (args)
                                      (anuna-imago::%harness-eval-handler args))))
               (let ((res (anuna-imago::handle-tool-frame
                           nil (list :tool-call "id-1" 'anuna-imago::harness-eval
                                     '(:form "(+ 1 2)")))))
                 (check (eq :vetoed (getf res :status))
                        "policy denies the :eval-permission tool call"))))
        (unregister-tool! 'anuna-imago::harness-eval)
        (when handle (remove-hook handle))
        (close-receipt-log! anuna-imago::*harness-eval-audit-log*)))
    (check (null (read-receipts path))
           "vetoed call never reached the pre-filter (no receipt)")
    (handler-case (delete-file path) (error () nil))))

;; =========================================================================
;; REQ-012 / TEST-017 — default tool-list is unchanged
;; =========================================================================

(defun test-m12-default-tool-list-unchanged ()
  (format t "~%-- m12-default-tool-list-unchanged (TEST-017) --~%")
  (flet ((tool-names ()
           (sort (loop for k being the hash-keys of anuna-imago::*tool-registry*
                       collect k)
                 #'string< :key #'symbol-name)))
    ;; No self-modification tool is present by default (REQ-012)…
    (dolist (name anuna-imago::*self-modification-tool-names*)
      (check (null (find-tool name))
             (format nil "~A absent from default registry" name)))
    ;; …and an install/uninstall cycle restores the registry exactly.
    (let ((baseline (tool-names))
          (anuna-imago::*active-theory-handle* :m12-t17-stub)
          (anuna-imago::*reasoner-ipc-call* #'%m12-stub-reasoner)
          (path (format nil "/tmp/imago-m12-t17-~D.log" (random 100000))))
      (check (eq :ok (anuna-imago::install-self-modification-tools!
                      :audit-log-path path)))
      (check (eq :ok (anuna-imago::uninstall-self-modification-tools!)))
      (check (equal baseline (tool-names))
             "install/uninstall round-trips the registry key set"))))

;; =========================================================================
;; NFR perf benchmarks — TEST-018 / TEST-019 / TEST-020 / TEST-021 / TEST-022
;; =========================================================================
;;
;; The reasoner is stubbed (*reasoner-ipc-call*), per the t11 plan task: the
;; budgets verified here cover the harness-side path (pre-filter, lift,
;; fact assert/retract, eval, receipt, origin index). Real Spindle IPC
;; latency is observed in deployment via OBS-004/OBS-007.

(defun %m12-p95 (times-ms)
  (let ((sorted (sort (copy-list times-ms) #'<)))
    (nth (floor (* 95/100 (length sorted))) sorted)))

(defun %m12-50-form-defmethod ()
  "A defmethod whose body has 50 forms, per NFR-001's workload. Wrapped in
a muffle-warning handler-bind because the eval thread would otherwise print
1000 CLOS same-method redefinition warnings to the global *error-output*."
  (with-output-to-string (s)
    (write-string "(handler-bind ((warning #'muffle-warning)) " s)
    (write-string "(defmethod m12-perf-target ((x integer)) (list" s)
    (dotimes (i 50) (format s " (+ x ~D)" i))
    (write-string ")))" s)))

(defun test-m12-latency-budget ()
  (format t "~%-- m12-latency-budget (TEST-018 / NFR-001) --~%")
  (unless (find-package :anuna-imago-user)
    (make-package :anuna-imago-user :use '(:cl :anuna-imago)))
  (with-m12-handler-fixture ()
    (let ((form (%m12-50-form-defmethod))
          (times nil)
          (non-ok 0))
      (clrhash *redefine-history*)
      ;; warm-up: first call pays one-off compilation
      (anuna-imago::%harness-eval-handler (list :form form))
      (dotimes (i 1000)
        (let ((start (get-internal-real-time)))
          (let ((res (anuna-imago::%harness-eval-handler (list :form form))))
            (unless (eq :ok (getf res :status)) (incf non-ok)))
          (push (/ (* 1000.0 (- (get-internal-real-time) start))
                   internal-time-units-per-second)
                times)))
      (check (zerop non-ok) (format nil "~D/1000 calls not :ok" non-ok))
      (let ((p95 (%m12-p95 times)))
        (format t "  1000 calls, p95: ~,2Fms~%" p95)
        (check (<= p95 100) (format nil "p95 ~,2Fms <= 100ms (NFR-001)" p95)))
      (clrhash *redefine-history*)
      (setf (fill-pointer *rollback-register*) 0))))

(defun test-m12-audit-completeness ()
  (format t "~%-- m12-audit-completeness (TEST-019 / NFR-002) --~%")
  ;; Short-window stand-in for the 30-day window: 300 invocations across
  ;; the three receipt-producing outcomes, each with a unique form text.
  ;; Completeness = every invocation has exactly one receipt (no gaps, no
  ;; duplicates), verified by set-equality on the verbatim form strings.
  (let ((path (format nil "/tmp/imago-m12-audit-~D.log" (random 100000)))
        (forms nil))
    (let ((anuna-imago::*reasoner-ipc-call* #'%m12-stub-reasoner)
          (anuna-imago::*active-theory-handle* :m12-stub-handle)
          (anuna-imago::*harness-eval-audit-log* (open-receipt-log path)))
      (unwind-protect
           (dotimes (i 300)
             (let ((form (case (mod i 3)
                           (0 (format nil "(+ ~D 0)" i))            ; :ok
                           (1 (format nil "(unintern 'x~D)" i))     ; :rejected
                           (2 (format nil "(error \"e~D\")" i)))))  ; :error
               (push form forms)
               (anuna-imago::%harness-eval-handler (list :form form))))
        (close-receipt-log! anuna-imago::*harness-eval-audit-log*)))
    (let* ((entries (read-receipts path))
           (logged  (mapcar (lambda (e) (getf e :form)) entries)))
      (check (= 300 (length entries)) "one receipt per invocation — no gaps")
      (check (= 300 (length (remove-duplicates logged :test #'string=)))
             "no duplicate receipts")
      (check (null (set-difference forms logged :test #'string=))
             "every submitted form appears in the log"))
    (handler-case (delete-file path) (error () nil))))

(defun test-m12-prefilter-false-positive-rate ()
  (format t "~%-- m12-prefilter-false-positive-rate (TEST-020 / NFR-003) --~%")
  (let* ((corpus-path (merge-pathnames "test/fixtures/spec-012-corpus.lisp"
                                       (asdf:system-source-directory :imago)))
         (forms (with-open-file (s corpus-path)
                  (let ((*package* (find-package :anuna-imago.test)))
                    (loop for form = (read s nil :eof)
                          until (eq form :eof)
                          collect form))))
         (rejections nil))
    (check (= 1000 (length forms)) "corpus contains exactly 1000 forms")
    (dolist (form forms)
      (let ((r (%harness-eval-prefilter form)))
        (unless (eq :pass r)
          (push (list form (getf r :rule)) rejections))))
    ;; With the stub reasoner allowing all corpus forms, every pre-filter
    ;; rejection is a false positive against the NFR-003 budget.
    (format t "  false positives: ~D/1000~%" (length rejections))
    (when rejections
      (format t "  first rejection: ~S~%" (first rejections)))
    (check (<= (length rejections) 10)
           (format nil "~D false positives <= 10 (1% of corpus, NFR-003)"
                   (length rejections)))))

(defun test-m12-reasoner-adjudication-latency ()
  (format t "~%-- m12-reasoner-adjudication-latency (TEST-021 / NFR-004) --~%")
  ;; NFR-004 window: lift-goal emission → reasoner tag. That is the
  ;; assert-facts / query-forbidden / retract-facts segment of the pipeline.
  (let ((anuna-imago::*reasoner-ipc-call* #'%m12-stub-reasoner)
        (handle :m12-stub-handle)
        (lift (%lift-form '(defmethod m12-adjudicated ((x integer)) (* x 2))))
        (times nil))
    (dotimes (i 1000)
      (let ((form-id (anuna-imago::%next-form-id))
            (start (get-internal-real-time)))
        (anuna-imago::%assert-lift-facts! handle form-id lift)
        (anuna-imago::%query-forbidden handle form-id)
        (anuna-imago::%retract-lift-facts! handle form-id lift)
        (push (/ (* 1000.0 (- (get-internal-real-time) start))
                 internal-time-units-per-second)
              times)))
    (let ((p95 (%m12-p95 times)))
      (format t "  1000 adjudications, p95: ~,3Fms~%" p95)
      (check (<= p95 50) (format nil "p95 ~,3Fms <= 50ms (NFR-004)" p95)))))

(defun test-m12-origin-index-storage-and-query ()
  (format t "~%-- m12-origin-index-storage-and-query (TEST-022 / NFR-005) --~%")
  (clrhash *redefine-history*)
  ;; Storage: an event for a <= 500-byte form stays under 2 KB printed size
  ;; and stores the verbatim text; > 500 bytes stores the md5 hash instead.
  (let* ((small (format nil "(defun small-target () ~S)"
                        (make-string 200 :initial-element #\a)))
         (event (anuna-imago::%record-definition!
                 'anuna-imago.test::small-target small 'm12 nil nil)))
    (check (string= small (getf event :defining-form)) "verbatim below 500 bytes")
    (check (<= (length (prin1-to-string event)) 2048)
           "event printed size <= 2KB (NFR-005 growth bound)"))
  ;; Query latency: 10^4 events across 100 symbols, query p95 <= 10ms.
  (clrhash *redefine-history*)
  (let ((syms (loop for i below 100
                    collect (intern (format nil "M12-IDX-~D" i)
                                    :anuna-imago.test))))
    (dotimes (i 10000)
      (anuna-imago::%record-definition!
       (nth (mod i 100) syms)
       (format nil "(defun f-~D () ~D)" i i) 'm12 nil nil))
    (let ((times nil))
      (dotimes (i 1000)
        (let ((start (get-internal-real-time)))
          (redefine-history (nth (mod i 100) syms))
          (push (/ (* 1000.0 (- (get-internal-real-time) start))
                   internal-time-units-per-second)
                times)))
      (let ((p95 (%m12-p95 times)))
        (format t "  10^4 entries, 1000 queries, p95: ~,3Fms~%" p95)
        (check (<= p95 10) (format nil "query p95 ~,3Fms <= 10ms (NFR-005)" p95)))))
  (clrhash *redefine-history*))

;; =========================================================================
;; Runner
;; =========================================================================

(defun run-m12-tests ()
  (format t "~%========================================~%")
  (format t " M12 — SPEC-012 self-modification port~%")
  (format t "========================================~%")
  (let ((*failures* 0))
    ;; t01
    (test-m12-scaffold-loaded)
    (test-m12-default-no-harness-eval)
    ;; t02 / CON-002
    (test-m12-prefilter-denies-cl-mischief)
    (test-m12-prefilter-denies-setf-bypasses)
    (test-m12-prefilter-denies-defmethod-against-safety-layer)
    (test-m12-prefilter-denies-defgeneric-against-safety-layer)
    (test-m12-prefilter-denies-safety-var-assignment)
    (test-m12-reasoner-ipc-in-safety-set)
    (test-m12-lift-captures-assignment-target)
    (test-m12-prefilter-passes-benign)
    ;; t03 / CON-003
    (test-m12-lift-defmethod-shape)
    (test-m12-lift-progn-buried-targets)
    (test-m12-lift-test-015-progn-unregister)
    (test-m12-lift-stable-across-whitespace)
    ;; t04 / CON-004
    (test-m12-tool-receipt-roundtrip)
    ;; t05 / CON-005
    (test-m12-origin-index-ordering)
    (test-m12-origin-index-large-form-hashed)
    ;; t06 / CON-006
    (test-m12-rollback-method-roundtrip)
    (test-m12-rollback-function-roundtrip)
    ;; t07 / CON-001
    (test-m12-handler-evaluates-benign-form)
    (test-m12-handler-rejects-prefilter-bypass)
    (test-m12-handler-vetoes-via-reasoner)
    (test-m12-handler-fails-closed-on-reasoner-error)
    (test-m12-handler-fails-closed-on-fact-seam-errors)
    (test-m12-handler-fails-closed-on-malformed-reasoner-evidence)
    (test-m12-handler-denies-manufactured-operator-authority)
    (test-m12-handler-error-during-eval)
    (test-m12-handler-receipt-on-every-phase)
    ;; t09 / REQ-001
    (test-m12-install-fails-closed-on-safety-fact-error)
    (test-m12-install-fn-registers-tool)
    ;; t10 / REQ-011
    (test-m12-persistence-across-save)
    ;; t11 — TEST-010 / TEST-017 + NFR benchmarks TEST-018..TEST-022
    (test-m12-eval-permission-policy-denial)
    (test-m12-default-tool-list-unchanged)
    (test-m12-latency-budget)
    (test-m12-audit-completeness)
    (test-m12-prefilter-false-positive-rate)
    (test-m12-reasoner-adjudication-latency)
    (test-m12-origin-index-storage-and-query)
    ;; introspection tools (post-spec affordances)
    (test-m12-tool-list-safety-layer)
    (test-m12-tool-redefine-history-summary)
    (test-m12-tool-list-rollbacks-and-rollback)
    (test-m12-tool-query-self-mod-receipts)
    (cond ((zerop *failures*)
           (format t "~%~%PASS — m12 component tests (t01..t11)~%")
           t)
          (t
           (format t "~%~%FAIL — ~D failures in m12 component tests~%" *failures*)
           (error "M12 test suite failed with ~D failure~:P" *failures*)))))
