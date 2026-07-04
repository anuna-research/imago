;;;; self-modification.lisp — SPEC-012 self-modification port (harness-eval)
;;;;
;;;; Implements:
;;;;   - CON-001 — harness-eval tool contract (handler at the bottom)
;;;;   - CON-002 — pre-filter denylist
;;;;   - CON-003 — reasoner lift function + safety-layer-symbol predicate
;;;;   - CON-004 — receipt log entry shape (harness-eval audit log)
;;;;   - CON-005 — symbol-origin index API
;;;;   - CON-006 — rollback register API (union shape per ADR-013 OQ-004)
;;;;
;;;; Beyond v0.1 spec floor (IMPL+, recorded in ADR-012):
;;;;   A1 — generalised mentions/2 floor invariant via safety-layer-symbol
;;;;   A2 — locked readtable + *read-eval* nil at the parse boundary
;;;;   A3 — tool struct accessors are in the safety-layer-symbol set
;;;;   A4 — defgeneric-targets/2 lift fact
;;;;   A7 — best-effort package lock (applied by install function)
;;;;
;;;; The opt-in tool itself (harness-eval) is registered by
;;;; (install-self-modification-tools!) which lives in
;;;; examples/self-modifying.lisp. This file does NOT auto-register.

(in-package #:anuna-imago)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-md5))
;; sb-mop is always loaded in SBCL (no require needed); accessed via the
;; sb-mop: package below.

;; =========================================================================
;; CON-003 / ADR-012 §A1 — safety-layer symbol set
;; =========================================================================
;;
;; Single set covering: SPEC-012 safety-layer-generic set + prefilter denylist
;; symbols + registry/struct mutation surface + eval/load/read primitives +
;; reader-macro primitives + thread primitives + harness-eval install
;; surface. Used by:
;;   - %harness-eval-prefilter (top-level defmethod / defgeneric target check)
;;   - %lift-form              (mentions/2 fact emission)
;;   - the floor theory        (forbidden(eval-call, F) :- mentions(F, S),
;;                                                         safety-layer-symbol(S).)
;;
;; The set is a defparameter (not a defconstant) so tests can extend it
;; without recompilation. The set is itself in the set, AND the pre-filter
;; rejects assignment (setf/setq/set/makunbound) to any safety-layer
;; variable (SELF-MOD-REVIEW BLOCKER-1) — so an agent's `harness-eval`
;; cannot mutate it, the audit log, the reasoner indirection, or the theory
;; handle from inside an evaluated form. Before that fix, bare-symbol
;; assignment slipped past %prefilter-setf (which only inspected cons
;; places) and past the lift (which only saw head-of-cons symbols).

(defparameter *safety-layer-symbols*
  '(;; SPEC-012 CON-003 originals
    invariant-filter-hook
    install-invariant-filter!
    uninstall-invariant-filter!
    %harness-eval-prefilter
    %harness-eval-handler
    tool-call
    dispatch-tool!
    register-tool!
    unregister-tool!
    %tool-receipt!
    ;; ADR-012 §A1 — registry / struct mutation surface
    *tool-registry*
    *tool-registry-lock*
    *valid-permissions*
    *valid-param-types*
    find-tool
    list-tools
    clear-all-tools
    make-tool
    tool-name
    tool-description
    tool-permission
    tool-schema
    tool-handler
    *open-receipt-logs*
    *credential-erasers*
    register-receipt-log-for-clean!
    register-credential-eraser!
    append-receipt!
    open-receipt-log
    close-receipt-log!
    *active-theory-handle*
    *invariant-filter-handle*
    *reasoner-ipc-call*          ; SELF-MOD-REVIEW BLOCKER-1 — the live
                                 ; reasoner indirection every query funcalls
    *redefine-history*
    *rollback-register*
    *safety-layer-symbols*
    *prefilter-denylist*
    *harness-eval-audit-log*
    install-self-modification-tools!
    uninstall-self-modification-tools!
    harness-eval
    ;; ADR-012 §A1 — eval/load/read primitives
    eval compile compile-file load read read-from-string
    read-preserving-whitespace
    ;; reader-macro primitives
    set-macro-character set-dispatch-macro-character set-syntax-from-char
    *readtable* copy-readtable make-dispatch-macro-character
    ;; SELF-MOD-REVIEW BLOCKER-1 — special-variable mutators. No legitimate
    ;; harness-eval use; here so the reasoner mentions/2 path vetoes them
    ;; even when the target symbol is computed at runtime (which the
    ;; structural pre-filter cannot resolve).
    set makunbound
    ;; thread primitives that bypass eval-thread isolation
    sb-thread:interrupt-thread sb-thread:terminate-thread
    sb-thread:make-thread sb-thread:join-thread
    ;; method/class introspection / mutation
    add-method remove-method find-method ensure-generic-function
    sb-mop:generic-function-methods sb-mop:intern-eql-specializer)
  "Symbols treated as untouchable by the floor invariants. Mention any of
these in a form's free-symbols and the reasoner returns +Δ via the
generalised mentions/2 rule. ADR-012 §A1.")

(defun safety-layer-symbol-p (sym)
  "T if SYM is in the safety-layer set."
  (and (symbolp sym) (member sym *safety-layer-symbols* :test #'eq)))

;; ---------------------------------------------------------------- categories
;;
;; Symbols in *safety-layer-symbols* are partitioned into categories so the
;; reasoner-veto handler can emit a teaching :hint instead of just naming
;; the offending symbol. Without categorisation, the agent treats each
;; veto as "this specific symbol is bad" and cycles through alternatives
;; from the same category one at a time (eval → read → load → … each
;; producing the same +Δ). The hint says "this entire category is
;; forbidden; here's an alternative class of tools".

(defparameter *safety-layer-categories*
  '((:eval-class
     (eval compile compile-file load read read-from-string
      read-preserving-whitespace)
     "Reader/evaluator primitives. Forbidden because they bypass the form-level safety filter — an agent could embed any defmethod in quoted data and run it via EVAL/READ/LOAD (ADR-012 §F2). Alternative for serialisation: line-oriented I/O with WITH-OPEN-FILE + WRITE-LINE/FORMAT to write, READ-LINE + SUBSEQ / PARSE-INTEGER / STRING= for manual parsing. Do NOT try to read s-expressions back; design your on-disk format as plain text records.")
    (:reader-macro-class
     (set-macro-character set-dispatch-macro-character set-syntax-from-char
      *readtable* copy-readtable make-dispatch-macro-character)
     "Reader-macro mutation. Forbidden because the harness reads submitted forms via a sealed readtable; mutating *readtable* or installing reader macros would let a later form interpret unrelated text as code (ADR-012 §F3).")
    (:thread-class
     (sb-thread:interrupt-thread sb-thread:terminate-thread
      sb-thread:make-thread sb-thread:join-thread)
     "Thread primitives. Forbidden because they can run arbitrary forms in another thread's context, bypassing the eval-thread timeout / safety chain (ADR-012 §F9). Stay on the calling thread.")
    (:method-mutate-class
     (add-method remove-method find-method ensure-generic-function
      sb-mop:generic-function-methods sb-mop:intern-eql-specializer)
     "Method-table mutation/introspection primitives. Use (defmethod NAME …) — the lift function sees the target through that path. For introspection of methods on a generic, this access is denied in v0.1; you can still call the generic and observe its behaviour.")
    (:safety-layer-target
     (invariant-filter-hook install-invariant-filter! uninstall-invariant-filter!
      %harness-eval-prefilter %harness-eval-handler tool-call dispatch-tool!
      register-tool! unregister-tool! %tool-receipt!)
     "Safety-stack functions and generics themselves. Redefining them would defeat the safety stack. Cannot be added to or replaced from inside harness-eval — operator action at the REPL is the only path.")
    (:tool-struct
     (tool-handler tool-permission tool-name tool-description tool-schema
      find-tool list-tools clear-all-tools make-tool)
     "Tool struct accessors / registry-introspection functions. Forbidden because they enable bypass via direct hash-table mutation. For introspection of registered tools, use the harness-list-tools / harness-describe-tool TOOLS — those are dispatched safely.")
    (:registry-table
     (*tool-registry* *tool-registry-lock* *valid-permissions* *valid-param-types*)
     "Tool registry storage. Direct (setf (gethash …) …) is forbidden. New tools cannot be added from inside harness-eval (REQ-001 — only the operator at the REPL can extend the tool surface).")
    (:audit-state
     (*open-receipt-logs* *credential-erasers* register-receipt-log-for-clean!
      register-credential-eraser! append-receipt! open-receipt-log
      close-receipt-log!)
     "Audit log primitives. Writing the audit log directly would enable forgery (ADR-012 §F10). The audit log is written automatically per harness-eval call; you cannot append entries yourself.")
    (:theory-state
     (*active-theory-handle* *invariant-filter-handle*)
     "Reasoner theory state. Replacing or clearing the theory would relax the safety floor. Operator action only.")
    (:harness-eval-state
     (*redefine-history* *rollback-register* *safety-layer-symbols*
      *prefilter-denylist* *harness-eval-audit-log*)
     "Self-modification port internal state. Read-only via the harness-redefine-history / harness-list-rollbacks / harness-list-safety-layer tools — direct mutation is forbidden.")
    (:harness-eval-install-fn
     (install-self-modification-tools! uninstall-self-modification-tools! harness-eval)
     "Install-fn pair and the harness-eval tool symbol itself. Cannot reinstall or uninstall the port from inside harness-eval — operator action."))
  "Partitions *safety-layer-symbols* into ten categories. Each entry is
  (category-keyword (symbol …) \"why string\")
The veto handler looks up a symbol's category to emit a teaching
hint; harness-list-safety-layer renders the categorised view when
called with :by-category t.")

(defun %symbol-category (sym)
  "Return the category keyword for SYM, or NIL if SYM is in
*safety-layer-symbols* but not yet partitioned (defensive — in
production every safety-layer symbol should be in some category)."
  (loop for (cat syms _) in *safety-layer-categories*
        when (member sym syms :test #'eq)
          return cat))

(defun %category-rationale (cat)
  "Return the 'why' paragraph for category CAT."
  (third (assoc cat *safety-layer-categories*)))

(defun %derivation-trigger-symbol (derivation)
  "Pull the safety-layer symbol that triggered the veto out of the
reasoner's derivation. The shipped floor produces derivations of the
shape ((forbidden eval-call F)
       (mentions|defmethod-targets|defgeneric-targets|defun-targets F SYMBOL)
       (safety-layer-symbol SYMBOL))
We pick the SYMBOL out of the second clause. Returns NIL on shapes we
don't recognise so future-proof rules degrade gracefully."
  (loop for clause in derivation
        when (and (consp clause)
                  (member (first clause)
                          '(mentions defmethod-targets defgeneric-targets
                            defun-targets))
                  (>= (length clause) 3))
          return (third clause)))

(defun %vetoed-hint (derivation)
  "Build the :hint string emitted on a vetoed receipt. Returns NIL when
the derivation doesn't pin a single trigger symbol (e.g. defence-in-
depth :no-active-theory case)."
  (let* ((sym (%derivation-trigger-symbol derivation))
         (cat (and sym (%symbol-category sym)))
         (why (and cat (%category-rationale cat))))
    (when cat
      (format nil "Triggered by mention of ~A (category ~A). ~A"
              sym cat why))))

;; =========================================================================
;; CON-002 — pre-filter (top-level structural denylist)
;; =========================================================================
;;
;; Fast structural check. Operates on a parsed form. Does NOT macroexpand,
;; does NOT walk past the top-level operator (and, for defmethod/defgeneric,
;; the target). Body inspection is the reasoner's job via *safety-layer-symbols*.

(defparameter *prefilter-denylist*
  '(;; SPEC-012 CON-002 table
    (unintern                        . :unintern)
    (delete-package                  . :delete-package)
    (sb-ext:save-lisp-and-die        . :save-lisp-and-die)
    (sb-ext:exit                     . :exit)
    (sb-ext:quit                     . :quit)
    (sb-ext:without-package-locks    . :without-package-locks)
    ;; ADR-012 §A1 — eval/load/read primitives at top level
    (eval                            . :eval-bypass)
    (compile                         . :compile-bypass)
    (compile-file                    . :compile-file-bypass)
    (load                            . :load-bypass)
    (read                            . :read-bypass)
    (read-from-string                . :read-from-string-bypass)
    (read-preserving-whitespace      . :read-bypass)
    ;; ADR-012 §A1 — reader-macro pollution (also in safety-layer set, but
    ;; cheap to catch at top level too)
    (set-macro-character             . :reader-macro-pollution)
    (set-dispatch-macro-character    . :reader-macro-pollution)
    (set-syntax-from-char            . :reader-macro-pollution)
    ;; ADR-012 §A1 — thread interrupt
    (sb-thread:interrupt-thread      . :thread-interrupt)
    (sb-thread:terminate-thread      . :thread-terminate))
  "Top-level operator → rejection rule keyword. The pre-filter rejects any
form whose CAR is a key here. Body-buried calls are caught by the reasoner
via *safety-layer-symbols*. CON-002 + ADR-012 §A1.")

(defun %prefilter-denylist-rule (op)
  (cdr (assoc op *prefilter-denylist* :test #'eq)))

(defun %harness-eval-prefilter (form)
  "Pre-filter per CON-002 + ADR-012 §A2/§A3/§A4. Returns :PASS or
  (:REJECTED :RULE <kw> :REASON <str>)."
  (cond
    ;; literals / atoms / nil — pre-filter has nothing to say
    ((not (consp form)) :pass)

    (t
     (let ((op (car form)))
       (cond
         ;; (setf (symbol-function …) …) / (setf (fdefinition …) …)
         ;; ADR-012 §A3: also (setf (tool-handler / tool-permission / … _) _)
         ;; ADR-012 §A1: also (setf (gethash _ <safety-layer-var>) _)
         ;; SELF-MOD-REVIEW BLOCKER-1: also bare-symbol places in the set.
         ((member op '(setf psetf))
          (%prefilter-setf form))

         ;; SELF-MOD-REVIEW BLOCKER-1 — (setq/psetq VAR VAL …) and the
         ;; runtime mutators (set / makunbound '<safety-var>). These bypass
         ;; the reasoner's structural lift exactly like the cons-place setf
         ;; forms did; the pre-filter is the hard floor that must catch them.
         ((member op '(setq psetq))
          (%prefilter-setq form))
         ((member op '(set makunbound))
          (%prefilter-symbol-mutator form))

         ;; defmethod against safety-layer target — CON-002
         ((and (eq op 'defmethod)
               (safety-layer-symbol-p (second form)))
          (list :status :rejected
                :rule :safety-layer-redefinition
                :reason (format nil "defmethod target ~S is in the safety-layer-symbols set"
                                (second form))))

         ;; defgeneric of safety-layer — ADR-012 §A4
         ((and (eq op 'defgeneric)
               (safety-layer-symbol-p (second form)))
          (list :status :rejected
                :rule :safety-layer-redefgeneric
                :reason (format nil "defgeneric target ~S is in the safety-layer-symbols set"
                                (second form))))

         ;; defun of a safety-layer symbol — also caught structurally (the
         ;; reasoner's defun-targets/2 rule duplicates this; cheap to catch
         ;; at top level)
         ((and (or (eq op 'defun) (eq op 'defmacro))
               (safety-layer-symbol-p (second form)))
          (list :status :rejected
                :rule :safety-layer-redefun
                :reason (format nil "~A target ~S is in the safety-layer-symbols set"
                                op (second form))))

         ;; top-level operator denylist
         ((let ((rule (%prefilter-denylist-rule op)))
            (when rule
              (list :status :rejected :rule rule
                    :reason (format nil "top-level operator ~S is on the prefilter denylist"
                                    op)))))

         (t :pass))))))

(defun %prefilter-setf (form)
  "Examine `(setf place value …)` for a place that mutates a safety-layer
binding without going through register-tool! / add-method / etc. Handles
multiple place/value pairs; any offending pair rejects the whole form."
  ;; setf/psetf take alternating place/value pairs — scan every place.
  (loop for (place value) on (cdr form) by #'cddr
        for r = (%prefilter-setf-place place)
        unless (eq r :pass) do (return-from %prefilter-setf r))
  :pass)

(defun %prefilter-setf-place (place)
  "Classify a single setf place. Returns :pass or a rejection plist."
  (cond
      ;; SELF-MOD-REVIEW BLOCKER-1: a bare-symbol place that names a
      ;; safety-layer variable (e.g. (setf *safety-layer-symbols* nil)).
      ((and (symbolp place) (safety-layer-symbol-p place))
       (list :status :rejected :rule :setf-safety-layer-variable
             :reason (format nil "(setf ~S …) assigns the safety-layer variable ~S"
                             place place)))
      ((not (consp place)) :pass)
      ((member (car place) '(symbol-function fdefinition))
       (list :status :rejected :rule :setf-symbol-function
             :reason "(setf (symbol-function|fdefinition …) …) bypasses defmethod and the reasoner"))
      ;; (setf (gethash KEY VAR) VAL) where VAR is a safety-layer variable
      ((and (eq (car place) 'gethash)
            (consp (cdr place))
            (consp (cddr place))
            (let ((var (third place)))
              (and (symbolp var) (safety-layer-symbol-p var))))
       (list :status :rejected :rule :setf-gethash-safety-layer
             :reason (format nil "(setf (gethash _ ~S) _) mutates a safety-layer table"
                             (third place))))
      ;; (setf (tool-* tool-instance) …)
      ((and (symbolp (car place))
            (member (car place) '(tool-handler tool-permission tool-name
                                  tool-description tool-schema)))
       (list :status :rejected :rule :setf-tool-accessor
             :reason (format nil "(setf (~S …) …) mutates a registered tool struct in place"
                             (car place))))
      ;; Place is a function-form whose head is itself a safety-layer symbol
      ((and (symbolp (car place)) (safety-layer-symbol-p (car place)))
       (list :status :rejected :rule :setf-safety-layer-place
             :reason (format nil "(setf (~S …) …) targets a safety-layer accessor" (car place))))
      (t :pass)))

(defun %prefilter-setq (form)
  "SELF-MOD-REVIEW BLOCKER-1 — `(setq/psetq VAR VALUE …)`. Reject if any
assigned VAR is a safety-layer variable."
  (loop for (var value) on (cdr form) by #'cddr
        when (and (symbolp var) (safety-layer-symbol-p var))
          do (return-from %prefilter-setq
               (list :status :rejected :rule :setq-safety-layer-variable
                     :reason (format nil "(setq ~S …) assigns the safety-layer variable ~S"
                                     var var))))
  :pass)

(defun %prefilter-symbol-mutator (form)
  "SELF-MOD-REVIEW BLOCKER-1 — `(set 'VAR …)` / `(makunbound 'VAR)`. Reject
when the (quoted) symbol argument is a safety-layer variable. A non-quoted
argument (computed at runtime) cannot be resolved structurally, so the head
symbol itself being in the safety set is the backstop — set/makunbound are
added to *safety-layer-symbols* so the reasoner mentions/2 path also fires."
  (let* ((arg (and (consp (cdr form)) (second form)))
         (sym (cond
                ((and (consp arg) (eq (car arg) 'quote)
                      (consp (cdr arg)) (symbolp (cadr arg)))
                 (cadr arg))
                ((symbolp arg) arg))))
    (if (and sym (safety-layer-symbol-p sym))
        (list :status :rejected :rule :symbol-mutator-safety-layer
              :reason (format nil "(~S '~S …) mutates the safety-layer variable ~S"
                              (car form) sym sym))
        :pass)))

;; =========================================================================
;; CON-003 — lift function (reasoner facts)
;; =========================================================================
;;
;; %lift-form parses a CL form (assumed to have passed the pre-filter) into
;; a plist of facts the reasoner can match against. NOT a macroexpander.
;; Walks the form once, collecting:
;;   - the top-level operator and target (per CON-003)
;;   - every symbol in functional position (head of a cons cell), including
;;     deeply nested ones — this catches body-buried calls per ADR-012 §A1
;;   - every symbol that is the target of a buried defmethod/defgeneric/defun —
;;     so `(progn (defmethod tool-call …))` produces
;;       (:defmethod-targets (tool-call))
;;     and the reasoner can derive forbidden via defmethod-targets/2.

(defun %symbol-eq (a b)
  (and (symbolp a) (symbolp b) (eq a b)))

(defun %defmethod-target-and-spec (form)
  "Given `(defmethod NAME [QUALIFIER] (LAMBDA-LIST) BODY...)`, return
   (values target qualifier specialisers-list)."
  (let* ((rest (cdr form))
         (target (first rest))
         (next   (second rest)))
    (cond
      ;; with qualifier: (defmethod name :before (ll) body)
      ((and next (or (keywordp next) (symbolp next)) (not (consp next)))
       (let ((ll (third rest)))
         (values target
                 (list next)
                 (and (listp ll) (mapcar #'%spec-name-of-arg ll)))))
      ;; primary method: (defmethod name (ll) body)
      ((listp next)
       (values target nil (mapcar #'%spec-name-of-arg next)))
      (t (values target nil nil)))))

(defun %spec-name-of-arg (arg)
  "From a lambda-list entry `var` or `(var class)` or `(var (eql foo))`,
return the specialiser identifier (class symbol or eql object)."
  (cond
    ((symbolp arg) t)                                  ; unspecialised → T
    ((and (consp arg) (consp (cdr arg)))
     (let ((spec (second arg)))
       (cond
         ((symbolp spec) spec)
         ((and (consp spec) (eq (car spec) 'eql))
          (list 'eql (second spec)))
         (t spec))))
    (t t)))

(defun %lift-form (form)
  "Per CON-003 + ADR-012 §A4. Returns plist:
  (:operator <symbol>
   :target <symbol-or-nil>
   :qualifier <list-or-nil>
   :specialisers <list-or-nil>
   :free-symbols <list>          ; every head-of-cons symbol seen
   :defmethod-targets <list>     ; every (defmethod TARGET …) target, incl. buried
   :defgeneric-targets <list>    ; ADR-012 §A4
   :defun-targets <list>)        ; (defun X) and (defmacro X)"
  (let ((operator (and (consp form) (car form)))
        (target nil) (qualifier nil) (specialisers nil)
        (free       (make-hash-table :test 'eq))
        (defm-tgts  (make-hash-table :test 'eq))
        (defg-tgts  (make-hash-table :test 'eq))
        (defn-tgts  (make-hash-table :test 'eq)))
    ;; top-level destructure
    (when (consp form)
      (case operator
        ((defmethod)
         (multiple-value-bind (tgt qual specs) (%defmethod-target-and-spec form)
           (setf target tgt qualifier qual specialisers specs)))
        ((defun defgeneric defmacro defparameter defvar defclass defstruct
                define-symbol-macro define-condition)
         (let ((tgt (second form)))
           (when (symbolp tgt) (setf target tgt))))))
    ;; deep walk for free-symbols + buried definition targets
    (labels ((walk (x)
               (cond
                 ((not (consp x)) nil)
                 (t
                  (let ((head (car x)))
                    (when (symbolp head) (setf (gethash head free) t))
                    (case head
                      ((defmethod)
                       (let ((tgt (and (consp (cdr x)) (second x))))
                         (when (symbolp tgt) (setf (gethash tgt defm-tgts) t))))
                      ((defgeneric)
                       (let ((tgt (and (consp (cdr x)) (second x))))
                         (when (symbolp tgt) (setf (gethash tgt defg-tgts) t))))
                      ((defun defmacro)
                       (let ((tgt (and (consp (cdr x)) (second x))))
                         (when (symbolp tgt) (setf (gethash tgt defn-tgts) t))))
                      ;; SELF-MOD-REVIEW BLOCKER-1 — assignment targets. A
                      ;; special var assigned in value position is never
                      ;; head-of-cons, so it would otherwise be invisible to
                      ;; mentions/2. Collect it so the reasoner floor can veto.
                      ((setf psetf)
                       (loop for (place val) on (cdr x) by #'cddr
                             when (symbolp place)
                               do (setf (gethash place free) t)))
                      ((setq psetq)
                       (loop for (var val) on (cdr x) by #'cddr
                             when (symbolp var)
                               do (setf (gethash var free) t)))
                      ((set makunbound)
                       (let ((a (and (consp (cdr x)) (second x))))
                         (cond
                           ((and (consp a) (eq (car a) 'quote)
                                 (consp (cdr a)) (symbolp (cadr a)))
                            (setf (gethash (cadr a) free) t))
                           ((symbolp a) (setf (gethash a free) t)))))
                      ((funcall apply)
                       ;; first arg is the function-designator
                       (let ((fn-arg (and (consp (cdr x)) (second x))))
                         (cond
                           ((symbolp fn-arg) (setf (gethash fn-arg free) t))
                           ((and (consp fn-arg)
                                 (eq (car fn-arg) 'function)
                                 (consp (cdr fn-arg))
                                 (symbolp (cadr fn-arg)))
                            (setf (gethash (cadr fn-arg) free) t))
                           ((and (consp fn-arg)
                                 (eq (car fn-arg) 'quote)
                                 (consp (cdr fn-arg))
                                 (symbolp (cadr fn-arg)))
                            (setf (gethash (cadr fn-arg) free) t))))))
                    (dolist (e (cdr x)) (walk e)))))))
      (walk form))
    (list :operator      operator
          :target        target
          :qualifier     qualifier
          :specialisers  specialisers
          :free-symbols  (loop for s being the hash-keys of free collect s)
          :defmethod-targets  (loop for s being the hash-keys of defm-tgts collect s)
          :defgeneric-targets (loop for s being the hash-keys of defg-tgts collect s)
          :defun-targets      (loop for s being the hash-keys of defn-tgts collect s))))

;; =========================================================================
;; CON-004 — harness-eval audit log entry
;; =========================================================================
;;
;; Distinct receipt-log instance from the SPEC-011 ASK/reply log: different
;; entry shape (CON-004 prose). Reuses receipt-log.lisp's mutex + stream
;; machinery via package-internal accessors (%receipt-log-stream and
;; %receipt-log-lock).

(defvar *harness-eval-audit-log* nil
  "RECEIPT-LOG instance bound by (install-self-modification-tools!).
   Closed by save-clean! via register-receipt-log-for-clean!.")

(defun %form-fingerprint (form-string)
  "SHA-256-ish hex digest of FORM-STRING for cross-referencing entries.
Uses sb-md5's md5sum for now (matches receipt-log.lisp's choice — content
addressing for dedup, not crypto)."
  (let ((bytes (sb-ext:string-to-octets form-string :external-format :utf-8)))
    (with-output-to-string (s)
      (loop for b across (sb-md5:md5sum-sequence bytes)
            do (format s "~(~2,'0x~)" b)))))

(defun %tool-receipt! (log &key tool agent-id form result-phase result-tag
                                elapsed-ms result-summary)
  "Append a CON-004 entry to LOG. Verbatim FORM never normalised /
truncated. Thread-safe via the underlying receipt-log mutex."
  (when log
    (sb-thread:with-mutex ((%receipt-log-lock log))
      (let* ((entry (list :tool tool
                          :agent-id (princ-to-string (or agent-id "?"))
                          :timestamp (iso-8601-now)
                          :form (or form "")
                          :form-hash (and form (%form-fingerprint form))
                          :result-phase result-phase
                          :result-tag result-tag
                          :elapsed-ms elapsed-ms
                          :result-summary result-summary))
             (stream (%receipt-log-stream log)))
        (when stream
          (let ((*print-pretty* nil) (*print-readably* nil) (*print-circle* t)
                (*print-length* 200) (*print-level* 12))
            (prin1 entry stream))
          (terpri stream)
          (force-output stream))
        entry))))

;; =========================================================================
;; CON-005 — symbol-origin index
;; =========================================================================
;;
;; *redefine-history*: hash-table SYMBOL → list of events, most-recent-first.
;; Events are appended by %record-definition! when a `harness-eval`
;; evaluation succeeds against a definition operator.

(defvar *redefine-history* (make-hash-table :test 'eq)
  "Symbol → list of definition events. Per CON-005.")

(defparameter *redefine-history-verbatim-cap* 500
  "Forms ≤ this many bytes are stored verbatim in the index event;
larger forms are stored as form-hash only.")

(defun redefine-history (symbol)
  "List of definition events for SYMBOL, most-recent-first."
  (gethash symbol *redefine-history*))

(defun last-redefinition (symbol)
  "Most recent event for SYMBOL, or NIL."
  (first (redefine-history symbol)))

(defun all-redefined-symbols ()
  "List of every symbol that has at least one event recorded."
  (loop for s being the hash-keys of *redefine-history* collect s))

(defun %record-definition! (target form-string agent-id prior-spec rollback-ref)
  "Push a CON-005 event onto *redefine-history* for TARGET. Returns the
event."
  (let* ((bytes (length form-string))
         (verbatim-p (<= bytes *redefine-history-verbatim-cap*))
         (event (list :symbol target
                      :defining-form (if verbatim-p
                                         form-string
                                         (%form-fingerprint form-string))
                      :form-bytes bytes
                      :agent-id agent-id
                      :timestamp (iso-8601-now)
                      :prior-spec prior-spec
                      :rollback-ref rollback-ref)))
    (push event (gethash target *redefine-history*))
    event))

;; =========================================================================
;; CON-006 + ADR-013 OQ-004 — rollback register (union shape)
;; =========================================================================
;;
;; Two record kinds:
;;   :method   — a defmethod redefinition; carries added-methods + removed-methods
;;   :function — a defun redefinition (ADR-013); carries prior-fdefinition
;;
;; rollback! is itself audited (writes a receipt-log entry tagged
;; :result-phase :rollback) and pushes a new origin-index event with
;; :agent-id :rollback.

(defvar *rollback-register* (make-array 0 :fill-pointer 0 :adjustable t)
  "Vector of rollback records (CON-006 + ADR-013 OQ-004 union shape).")

(defun rollback-records ()
  "List view of *rollback-register*, lowest-index first."
  (coerce *rollback-register* 'list))

(defun find-rollback-records-for (symbol)
  "All rollback records targeting SYMBOL (generic name OR function name)."
  (loop for r across *rollback-register*
        when (eq (getf r :symbol) symbol)
          collect r))

(defun %method-set (gf-symbol)
  "Snapshot of methods on the generic named GF-SYMBOL; NIL if not bound."
  (when (and (fboundp gf-symbol)
             (typep (fdefinition gf-symbol) 'standard-generic-function))
    (copy-list (sb-mop:generic-function-methods (fdefinition gf-symbol)))))

(defun %push-method-rollback! (target qualifier specialisers
                                added-methods removed-methods
                                agent-id form-hash)
  "Push a :method-kind rollback record. Returns the record."
  (let* ((idx (length *rollback-register*))
         (rec (list :kind :method
                    :index idx
                    :symbol target
                    :qualifier qualifier
                    :specialisers specialisers
                    :added-methods added-methods
                    :removed-methods removed-methods
                    :installed-at (iso-8601-now)
                    :installed-by agent-id
                    :form-hash form-hash
                    :rolled-back nil)))
    (vector-push-extend rec *rollback-register*)
    rec))

(defun %push-function-rollback! (sym prior-fdefinition prior-bound-p
                                      agent-id form-hash)
  "Push a :function-kind rollback record (ADR-013 OQ-004)."
  (let* ((idx (length *rollback-register*))
         (rec (list :kind :function
                    :index idx
                    :symbol sym
                    :prior-fdefinition prior-fdefinition
                    :prior-bound-p prior-bound-p
                    :installed-at (iso-8601-now)
                    :installed-by agent-id
                    :form-hash form-hash
                    :rolled-back nil)))
    (vector-push-extend rec *rollback-register*)
    rec))

(defun %audit-rollback! (rec status)
  "Write a CON-004 entry tagged :result-phase :rollback for the rollback
of REC. STATUS is the rollback! return value."
  (when *harness-eval-audit-log*
    (%tool-receipt! *harness-eval-audit-log*
                    :tool 'harness-eval :agent-id :rollback
                    :form (format nil "(rollback! ~D)" (getf rec :index))
                    :result-phase :rollback
                    :result-tag status
                    :elapsed-ms 0
                    :result-summary (list :index (getf rec :index)
                                          :symbol (getf rec :symbol)
                                          :kind (getf rec :kind)))))

(defun %record-rollback-event! (rec)
  "Push a CON-005 event with :agent-id :rollback for the rolled-back symbol."
  (let ((sym (getf rec :symbol)))
    (push (list :symbol sym
                :defining-form (format nil "(rollback! ~D)" (getf rec :index))
                :form-bytes 0
                :agent-id :rollback
                :timestamp (iso-8601-now)
                :prior-spec (list :rolled-back-from (getf rec :form-hash))
                :rollback-ref (getf rec :index))
          (gethash sym *redefine-history*))))

(defun %rollback-method-record! (rec)
  (let* ((sym (getf rec :symbol))
         (gf  (and (fboundp sym) (fdefinition sym))))
    (when (typep gf 'standard-generic-function)
      (dolist (m (getf rec :added-methods))
        (handler-case (remove-method gf m) (error () nil)))
      (dolist (m (getf rec :removed-methods))
        (handler-case (add-method gf m) (error () nil))))
    (setf (getf rec :rolled-back) t)))

(defun %rollback-function-record! (rec)
  (let ((sym (getf rec :symbol)))
    (cond
      ((getf rec :prior-bound-p)
       (setf (symbol-function sym) (getf rec :prior-fdefinition)))
      (t (handler-case (fmakunbound sym) (error () nil))))
    (setf (getf rec :rolled-back) t)))

(defun rollback! (index)
  "Re-install the prior method (or symbol-function) recorded at INDEX.
Returns :OK, :NO-SUCH-RECORD, or :ALREADY-ROLLED-BACK. Writes audit + index
entries on success."
  (cond
    ((or (not (integerp index)) (minusp index)
         (>= index (length *rollback-register*)))
     :no-such-record)
    (t
     (let ((rec (aref *rollback-register* index)))
       (cond
         ((getf rec :rolled-back)
          (%audit-rollback! rec :already-rolled-back)
          :already-rolled-back)
         ((eq (getf rec :kind) :method)
          (%rollback-method-record! rec)
          (%record-rollback-event! rec)
          (%audit-rollback! rec :ok)
          :ok)
         ((eq (getf rec :kind) :function)
          (%rollback-function-record! rec)
          (%record-rollback-event! rec)
          (%audit-rollback! rec :ok)
          :ok)
         (t :no-such-record))))))

;; =========================================================================
;; CON-001 — harness-eval handler (orchestrator)
;; =========================================================================
;;
;; Steps for every call:
;;   1. parse :form via locked readtable + *read-eval* nil  (ADR-012 §A2)
;;   2. %harness-eval-prefilter
;;   3. on pass: %lift-form, assert per-call facts, query
;;      (forbidden eval-call <form-id>), retract under unwind-protect
;;   4. on -Δ/-∂: capture method-set / fdefinition for rollback, eval the
;;      form in a worker thread under :timeout (ADR-013 OQ-001), capture
;;      added methods / fdefinition for rollback, record origin event
;;   5. write CON-004 receipt at every termination point
;;
;; Always returns a plist; never raises to the caller (errors converted to
;; (:status :error :phase :evaluation …)).

(defparameter *harness-eval-result-truncate-bytes* 4096
  "Per ADR-013 OQ-003 — prin1'd values larger than this are truncated.")

(defparameter *harness-eval-default-timeout-ms* 1000)
(defparameter *harness-eval-max-timeout-ms*     30000)
(defparameter *harness-eval-default-package* :anuna-imago-user)

(defvar *form-counter* 0)
(defvar *form-counter-lock* (sb-thread:make-mutex :name "form-counter"))

(defun %next-form-id ()
  (sb-thread:with-mutex (*form-counter-lock*)
    (incf *form-counter*)
    (intern (format nil "FORM-~D" *form-counter*) :keyword)))

(defun %bounded-prin1 (value)
  "Per ADR-013 OQ-003: bound the printer + truncate at *harness-eval-result-truncate-bytes*."
  (let* ((s (let ((*print-circle* t)
                  (*print-length* 100)
                  (*print-level* 10)
                  (*print-pretty* nil)
                  (*print-readably* nil))
              (with-output-to-string (out) (prin1 value out)))))
    (cond
      ((<= (length s) *harness-eval-result-truncate-bytes*) s)
      (t (concatenate 'string
                      (subseq s 0 *harness-eval-result-truncate-bytes*)
                      "…[TRUNCATED]")))))

(defun %parse-form-locked (form-string)
  "ADR-012 §A2 — read FORM-STRING with a pristine readtable and *read-eval* nil.
Returns (values form parse-error-or-nil)."
  (handler-case
      (let ((*readtable* (copy-readtable nil))
            (*read-eval* nil))
        (values (read-from-string form-string) nil))
    (error (c) (values nil c))))

(defun %assert-lift-facts! (handle form-id lift)
  "Assert per-call facts for FORM-ID drawn from LIFT plist. Returns nothing
useful; %retract-lift-facts! mirrors this."
  (handler-case (assert-fact! handle (list 'operator-of form-id (getf lift :operator)))
    (error () nil))
  (when (getf lift :target)
    (handler-case (assert-fact! handle (list 'operator-target form-id (getf lift :target)))
      (error () nil)))
  (dolist (g (getf lift :defmethod-targets))
    (handler-case (assert-fact! handle (list 'defmethod-targets form-id g))
      (error () nil)))
  (dolist (g (getf lift :defgeneric-targets))
    (handler-case (assert-fact! handle (list 'defgeneric-targets form-id g))
      (error () nil)))
  (dolist (s (getf lift :defun-targets))
    (handler-case (assert-fact! handle (list 'defun-targets form-id s))
      (error () nil)))
  (dolist (s (getf lift :free-symbols))
    (handler-case (assert-fact! handle (list 'mentions form-id s))
      (error () nil))))

(defun %retract-lift-facts! (handle form-id lift)
  (handler-case (retract-fact! handle (list 'operator-of form-id (getf lift :operator)))
    (error () nil))
  (when (getf lift :target)
    (handler-case (retract-fact! handle (list 'operator-target form-id (getf lift :target)))
      (error () nil)))
  (dolist (g (getf lift :defmethod-targets))
    (handler-case (retract-fact! handle (list 'defmethod-targets form-id g))
      (error () nil)))
  (dolist (g (getf lift :defgeneric-targets))
    (handler-case (retract-fact! handle (list 'defgeneric-targets form-id g))
      (error () nil)))
  (dolist (s (getf lift :defun-targets))
    (handler-case (retract-fact! handle (list 'defun-targets form-id s))
      (error () nil)))
  (dolist (s (getf lift :free-symbols))
    (handler-case (retract-fact! handle (list 'mentions form-id s))
      (error () nil))))

(defun %assert-safety-layer-facts! (handle)
  "Install one (safety-layer-symbol S) fact per element of
*safety-layer-symbols*. Called by INSTALL-SELF-MODIFICATION-TOOLS! after
load-theory and before the first harness-eval call."
  (dolist (s *safety-layer-symbols*)
    (handler-case (assert-fact! handle (list 'safety-layer-symbol s))
      (error () nil))))

(defun %query-forbidden (handle form-id)
  "Returns the proof-result plist or NIL on IPC error."
  (handler-case (query handle (list 'forbidden 'eval-call form-id))
    (error () nil)))

(defun %eval-form-with-timeout (form package-name timeout-ms)
  "Evaluate FORM in PACKAGE-NAME under TIMEOUT-MS. Returns one of:
  (list :ok <value> <stdout-string> <elapsed-ms>)
  (list :error <condition> <stdout-string> <elapsed-ms>)
  :timeout"
  (let* ((mb       (make-mailbox))
         (start    (get-internal-real-time))
         (pkg      (or (find-package package-name)
                       (find-package :cl-user)))
         (worker
           (sb-thread:make-thread
            (lambda ()
              (let ((buf (make-string-output-stream)))
                (handler-case
                    (let ((*package* pkg)
                          (*standard-output* buf))
                      (let ((value (eval form)))
                        (send! mb (list :ok value
                                        (get-output-stream-string buf)
                                        (%elapsed-ms start)))))
                  (error (c)
                    (send! mb (list :error c
                                    (get-output-stream-string buf)
                                    (%elapsed-ms start)))))))
            :name "harness-eval-worker"))
         (reply (receive! mb :timeout (/ (max 1 timeout-ms) 1000.0))))
    (cond
      ((eq reply :timeout)
       (handler-case (sb-thread:terminate-thread worker) (error () nil))
       :timeout)
      (t reply))))

(defun %elapsed-ms (start)
  (round (* 1000 (/ (- (get-internal-real-time) start)
                    internal-time-units-per-second))))

(defun %form-rollback-prep (lift)
  "Snapshot pre-eval state for every definition target the lift surfaced
— top-level OR buried inside progn/let/etc. Returns an alist:
  ((SYMBOL :method <pre-method-set>) ...)
  ((SYMBOL :function <prior-fn> <prior-bound-p>) ...)

The buried-target gap was a real bug: agents bundling
\"(progn (in-package …) (defun foo …) (defun bar …))\" produced no
origin-index events and no rollback records under the previous
implementation, because top-level operator was `progn` and target was
nil. %lift-form already populates :defun-targets / :defmethod-targets
/ :defgeneric-targets via deep walk; we now consult those lists too."
  (let ((entries nil)
        (seen    (make-hash-table :test 'eq))
        (op       (getf lift :operator))
        (target   (getf lift :target)))
    (labels ((capture-method (sym)
               (push (list sym :method (%method-set sym)) entries)
               (setf (gethash sym seen) t))
             (capture-function (sym)
               (let ((bound (and (fboundp sym) (not (macro-function sym)))))
                 (push (list sym :function
                             (and bound (symbol-function sym))
                             bound)
                       entries)
                 (setf (gethash sym seen) t))))
      ;; Top-level
      (cond
        ((and (eq op 'defmethod) target)              (capture-method target))
        ((and (or (eq op 'defun) (eq op 'defmacro))
              target)                                  (capture-function target)))
      ;; Buried — :defmethod-targets / :defgeneric-targets are method
      ;; surface; :defun-targets covers defun + defmacro buried.
      (dolist (s (getf lift :defmethod-targets))
        (unless (gethash s seen) (capture-method s)))
      (dolist (s (getf lift :defgeneric-targets))
        (unless (gethash s seen) (capture-method s)))
      (dolist (s (getf lift :defun-targets))
        (unless (gethash s seen) (capture-function s))))
    (nreverse entries)))

(defun %form-rollback-record (lift agent-id form-hash pre-state)
  "After a successful eval, push rollback records for every target whose
post-state diverged from PRE-STATE. PRE-STATE is the alist returned by
%form-rollback-prep. Returns the list of newly-pushed rollback records
(possibly empty)."
  (let ((records      nil)
        (qualifier    (getf lift :qualifier))
        (specialisers (getf lift :specialisers)))
    (dolist (entry pre-state)
      (let ((sym  (first entry))
            (kind (second entry)))
        (case kind
          (:method
           (let* ((pre   (third entry))
                  (post  (%method-set sym))
                  (added (set-difference post pre))
                  (removed (set-difference pre post)))
             (when (or added removed)
               (push (%push-method-rollback! sym qualifier specialisers
                                              added removed
                                              agent-id form-hash)
                     records))))
          (:function
           (let ((prior-fn    (third entry))
                 (prior-bound (fourth entry)))
             (push (%push-function-rollback! sym prior-fn prior-bound
                                              agent-id form-hash)
                   records))))))
    (nreverse records)))

(defun %form-record-definition (lift form-string agent-id rollback-records)
  "Push an origin-index event for every symbol the form (re)defined,
top-level OR buried. ROLLBACK-RECORDS is the list returned by
%form-rollback-record; we match by symbol so each event's :rollback-ref
points at the right rollback record (or nil for events that don't have
a rollback record, e.g. defparameter / defclass)."
  (let* ((rb-by-sym (mapcar (lambda (r) (cons (getf r :symbol) (getf r :index)))
                            rollback-records))
         (recorded  (make-hash-table :test 'eq))
         (op        (getf lift :operator))
         (target    (getf lift :target)))
    (labels ((record (sym kind-keyword)
               (unless (gethash sym recorded)
                 (let ((rb-idx (cdr (assoc sym rb-by-sym))))
                   (%record-definition! sym form-string agent-id
                                         (and kind-keyword
                                              (list :kind kind-keyword))
                                         rb-idx)
                   (setf (gethash sym recorded) t)))))
      ;; Top-level: respect the broader CON-005 set including defparameter
      ;; / defvar / defclass / defstruct that don't have a rollback record.
      (when (and target
                 (member op '(defun defmethod defgeneric defmacro
                              defparameter defvar defclass defstruct
                              define-condition define-symbol-macro)))
        (record target (cond ((eq op 'defmethod)  :method)
                             ((eq op 'defgeneric) :generic)
                             ((eq op 'defun)      :function)
                             ((eq op 'defmacro)   :macro)
                             (t                   :variable))))
      ;; Buried — only the def shapes %lift-form tracks (defmethod /
      ;; defgeneric / defun / defmacro). Buried defparameter / defvar
      ;; would need additional walker support; flagged as a v0.2
      ;; extension.
      (dolist (s (getf lift :defmethod-targets))   (record s :method))
      (dolist (s (getf lift :defgeneric-targets))  (record s :generic))
      (dolist (s (getf lift :defun-targets))       (record s :function)))))

(defun %harness-eval-handler (args)
  "CON-001 entry point. ARGS is a plist with :form (string, required),
:package (string or keyword, optional), :timeout (integer ms, optional).

Always returns a plist; never raises."
  (let* ((agent-id    (when *current-agent* (agent-id *current-agent*)))
         (form-string (getf args :form))
         (pkg-arg     (getf args :package))
         (pkg-name    (cond
                        ((null pkg-arg) *harness-eval-default-package*)
                        ((stringp pkg-arg) (intern (string-upcase pkg-arg) :keyword))
                        ((symbolp pkg-arg) (intern (string (symbol-name pkg-arg)) :keyword))
                        (t *harness-eval-default-package*)))
         (timeout-ms  (max 1 (min *harness-eval-max-timeout-ms*
                                  (or (getf args :timeout)
                                      *harness-eval-default-timeout-ms*))))
         (start (get-internal-real-time)))
    (cond
      ((or (null form-string) (not (stringp form-string)))
       (let ((res (list :status :error :phase :evaluation
                        :condition-type 'invalid-argument
                        :message ":form must be a non-empty string"
                        :elapsed-ms 0)))
         (%emit-receipt! 'harness-eval agent-id (or form-string "") :evaluation :error 0
                         (list :condition-type 'invalid-argument))
         res))

      (t
       (multiple-value-bind (form parse-err) (%parse-form-locked form-string)
         (cond
           (parse-err
            (let ((res (list :status :error :phase :evaluation
                             :condition-type 'parse-error
                             :message (princ-to-string parse-err)
                             :elapsed-ms (%elapsed-ms start))))
              (%emit-receipt! 'harness-eval agent-id form-string :evaluation :error
                              (%elapsed-ms start)
                              (list :condition-type 'parse-error
                                    :message (princ-to-string parse-err)))
              res))

           (t
            (%after-parse-pipeline form form-string pkg-name timeout-ms agent-id start))))))))

(defun %emit-receipt! (tool agent-id form-string phase tag elapsed-ms summary)
  (when *harness-eval-audit-log*
    (%tool-receipt! *harness-eval-audit-log*
                    :tool tool
                    :agent-id agent-id
                    :form form-string
                    :result-phase phase
                    :result-tag tag
                    :elapsed-ms elapsed-ms
                    :result-summary summary)))

(defun %after-parse-pipeline (form form-string pkg-name timeout-ms agent-id start)
  ;; Step 2 — prefilter
  (let ((pf (%harness-eval-prefilter form)))
    (cond
      ((not (eq pf :pass))
       (let* ((rule (getf pf :rule))
              (reason (getf pf :reason))
              (res (list :status :rejected :phase :pre-filter
                         :rule rule :reason reason)))
         (%emit-receipt! 'harness-eval agent-id form-string
                         :pre-filter :rejected (%elapsed-ms start)
                         (list :rule rule :reason reason))
         res))

      (t
       (%after-prefilter-pipeline form form-string pkg-name timeout-ms agent-id start)))))

(defun %after-prefilter-pipeline (form form-string pkg-name timeout-ms agent-id start)
  ;; Step 3 — lift + reasoner
  (let* ((lift (%lift-form form))
         (form-id (%next-form-id))
         (handle *active-theory-handle*))
    (cond
      ((null handle)
       ;; No theory installed → fail safe by treating as vetoed. The
       ;; install function (REQ-001 / REQ-005) refuses to register the
       ;; tool without a theory; this branch is defence-in-depth.
       (let ((res (list :status :vetoed :phase :reasoner
                        :goal (list 'forbidden 'eval-call form-id)
                        :derivation '((no-active-theory))
                        :time-ms 0)))
         (%emit-receipt! 'harness-eval agent-id form-string
                         :reasoner :vetoed (%elapsed-ms start)
                         (list :form-id form-id :reason :no-active-theory))
         res))

      (t
       (%assert-lift-facts! handle form-id lift)
       (let ((veto-result nil))
         (unwind-protect
             (let ((proof (%query-forbidden handle form-id)))
               (when (proof-result-positive-p proof)
                 (let* ((derivation (getf proof :derivation))
                        (hint       (%vetoed-hint derivation)))
                   (setf veto-result
                         (list :status :vetoed :phase :reasoner
                               :goal (list 'forbidden 'eval-call form-id)
                               :derivation derivation
                               :hint hint
                               :time-ms (or (getf proof :time-ms) 0))))))
           (%retract-lift-facts! handle form-id lift))
         (cond
           (veto-result
            (%emit-receipt! 'harness-eval agent-id form-string
                            :reasoner :vetoed (%elapsed-ms start)
                            (list :form-id form-id
                                  :goal (getf veto-result :goal)
                                  :derivation (getf veto-result :derivation)
                                  :hint (getf veto-result :hint)))
            veto-result)
           (t
            (%after-reasoner-pipeline form form-string lift form-id
                                       pkg-name timeout-ms agent-id start))))))))

(defun %after-reasoner-pipeline (form form-string lift form-id pkg-name timeout-ms agent-id start)
  ;; Step 4 — capture pre-state for every (re)defined target (top-level
  ;; OR buried), eval, capture post-state diffs, push rollback records
  ;; per target, push origin-index events per target.
  (let ((pre-state (%form-rollback-prep lift)))
    (let ((reply (%eval-form-with-timeout form pkg-name timeout-ms))
          (form-hash (%form-fingerprint form-string)))
      (cond
        ((eq reply :timeout)
         (let ((res (list :status :timeout :phase :evaluation
                          :elapsed-ms timeout-ms)))
           (%emit-receipt! 'harness-eval agent-id form-string
                           :evaluation :timeout timeout-ms
                           (list :form-id form-id))
           res))
        ((eq (first reply) :error)
         (let* ((c (second reply))
                (stdout (third reply))
                (elapsed (fourth reply))
                (res (list :status :error :phase :evaluation
                           :condition-type (type-of c)
                           :message (princ-to-string c)
                           :elapsed-ms elapsed
                           :stdout stdout)))
           (%emit-receipt! 'harness-eval agent-id form-string
                           :evaluation :error elapsed
                           (list :form-id form-id
                                 :condition-type (type-of c)
                                 :message (princ-to-string c)))
           res))
        (t   ; (:ok value stdout elapsed)
         (let* ((value (second reply))
                (stdout (third reply))
                (elapsed (fourth reply))
                (rollback-records (%form-rollback-record lift agent-id form-hash
                                                          pre-state))
                (res (list :status :ok :phase :evaluated
                           :value (%bounded-prin1 value)
                           :stdout stdout
                           :elapsed-ms elapsed)))
           (%form-record-definition lift form-string agent-id rollback-records)
           (%emit-receipt! 'harness-eval agent-id form-string
                           :evaluated :ok elapsed
                           (list :form-id form-id
                                 :value-fingerprint
                                 (%form-fingerprint (%bounded-prin1 value))
                                 :rollback-indices
                                 (mapcar (lambda (r) (getf r :index))
                                         rollback-records)))
           res))))))
