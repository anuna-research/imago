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

(defun m12-reasoner-protected-probe ()
  (incf *m12-reasoner-protected-calls*)
  :protected-action-ran)

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

(defun test-m12-handler-fails-closed-on-malformed-reasoner-evidence ()
  "SPEC-014 TEST-025: missing and unknown proof tags cannot reach EVAL."
  (format t "~%-- m12-handler-fails-closed-on-malformed-reasoner-evidence (SPEC-014 TEST-025) --~%")
  (%exercise-m12-reasoner-failure
   (lambda () (list :derivation nil :time-ms 1))
   "missing proof tag")
  (%exercise-m12-reasoner-failure
   (lambda () (list :tag :unknown-proof :derivation nil :time-ms 1))
   "unknown proof tag"))

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
    (test-m12-handler-fails-closed-on-malformed-reasoner-evidence)
    (test-m12-handler-error-during-eval)
    (test-m12-handler-receipt-on-every-phase)
    ;; t09 / REQ-001
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
           nil))))
