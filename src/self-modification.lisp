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
  (require :sb-md5)
  (require :sb-posix))
;; sb-mop is always loaded in SBCL (no require needed); accessed via the
;; sb-mop: package below.

;; Harness evaluation keeps dispatch authority outside named dynamic state.
;; The active ceiling is keyed by the VM's actual thread address, while a weak
;; per-agent map pins the first canonical registry-symbol allowlist.  These
;; closure-owned tables are deliberately not exposed as mutable Lisp objects.
(defun %tool-name-equal-p (left right)
  "Compare provider tool-name designators without trusting package identity."
  (let ((left-name (typecase left (symbol (symbol-name left)) (string left)))
        (right-name (typecase right (symbol (symbol-name right)) (string right))))
    (and left-name right-name (string-equal left-name right-name))))

(defun %canonical-evaluation-tool-names (tool-names)
  "Resolve TOOL-NAMES to immutable registry symbol identities.
Unknown designators are omitted. Dotted, cyclic, or overlong allowlists fail
closed.  The 256-cell bound exceeds the finite supported tool surface."
  (let ((seen (make-hash-table :test #'eq))
        (cursor tool-names)
        (canonical nil))
    (loop for count from 0
          do (cond
               ((null cursor)
                (return (remove-duplicates (nreverse canonical) :test #'eq)))
               ((or (>= count 256)
                    (atom cursor)
                    (gethash cursor seen))
                (return nil))
               (t
                (setf (gethash cursor seen) t)
                (let ((tool (find-tool (car cursor))))
                  (when tool (push (tool-name tool) canonical)))
                (setf cursor (cdr cursor)))))))

(defun %evaluation-authority-thread-key ()
  "Return the actual VM thread identity, independent of special bindings."
  (sb-sys:sap-int (sb-thread:current-thread-sap)))

(let ((evaluation-authority-by-thread (make-hash-table :test #'eql))
      (initial-authority-by-agent
        (make-hash-table :test #'eq :weakness :key))
      (evaluation-authority-lock
        (sb-thread:make-mutex :name "evaluation-tool-authority")))
  (defun %call-with-evaluation-tool-authority (agent tool-names thunk)
    "Call THUNK below AGENT's immutable first-evaluation dispatch ceiling.
The current canonical allowlist may shrink that ceiling.  An already-active
ceiling wins over every nested request on the actual VM thread."
    (let ((thread-key (%evaluation-authority-thread-key)))
      (multiple-value-bind (existing present-p)
          (sb-thread:with-mutex (evaluation-authority-lock)
            (gethash thread-key evaluation-authority-by-thread))
        (declare (ignore existing))
        (if present-p
            (funcall thunk)
            (let* ((current (%canonical-evaluation-tool-names tool-names))
                   (ceiling
                     (sb-thread:with-mutex (evaluation-authority-lock)
                       (multiple-value-bind (saved saved-p)
                           (gethash agent initial-authority-by-agent)
                         (let ((narrowed
                                 (if saved-p
                                     (remove-if-not
                                      (lambda (name)
                                        (member name saved :test #'eq))
                                      current)
                                     current)))
                           (setf (gethash agent initial-authority-by-agent)
                                 (copy-list narrowed))))))
                   (effective (copy-list ceiling))
                   (record (list effective agent)))
              (sb-thread:with-mutex (evaluation-authority-lock)
                (setf (gethash thread-key evaluation-authority-by-thread)
                      record))
              (unwind-protect
                   (funcall thunk)
                (unwind-protect
                     ;; The visible slot feeds provider advertisement and
                     ;; ordinary dispatch. Preserve reductions, but erase
                     ;; additions before publishing the worker result.
                     (when agent
                       (handler-case
                           (let* ((post
                                    (%canonical-evaluation-tool-names
                                     (agent-tools agent)))
                                  (sanitized
                                    (remove-if-not
                                     (lambda (name)
                                       (member name ceiling :test #'eq))
                                     post)))
                             (setf (agent-tools agent)
                                   (copy-list sanitized)))
                         (error ()
                           (ignore-errors (setf (agent-tools agent) nil)))))
                  ;; Record removal runs even if malformed agent state makes
                  ;; slot sanitization signal unexpectedly.
                  (sb-thread:with-mutex (evaluation-authority-lock)
                    (when (eq record
                              (gethash thread-key
                                       evaluation-authority-by-thread))
                      (remhash thread-key
                               evaluation-authority-by-thread))))))))))

  (defun %evaluation-tool-permitted-p (tool-name)
    "Return PERMITTED-P, ACTIVE-P, and the matched allowlist designator.
When ACTIVE-P is true, callers must ignore dynamic agent/operator authority."
    (let ((thread-key (%evaluation-authority-thread-key)))
      (multiple-value-bind (record active-p)
          (sb-thread:with-mutex (evaluation-authority-lock)
            (gethash thread-key evaluation-authority-by-thread))
        (let ((allowed (and active-p
                            (find tool-name (first record)
                                  :test #'%tool-name-equal-p))))
          (values (not (null allowed)) active-p (or allowed tool-name))))))

  (defun %effective-agent-tool-names
      (agent &optional (current (slot-value agent 'tools)))
    "Apply AGENT's monotonic evaluation ceiling to its current visible tools."
    (multiple-value-bind (ceiling pinned-p)
        (sb-thread:with-mutex (evaluation-authority-lock)
          (gethash agent initial-authority-by-agent))
      (if pinned-p
          (let ((canonical (%canonical-evaluation-tool-names current)))
            (remove-if-not
             (lambda (name) (member name ceiling :test #'eq))
             canonical))
          current))))

(defmethod agent-tools :around ((agent agent))
  "Expose at most the immutable ceiling pinned by AGENT's first evaluation."
  (%effective-agent-tool-names agent (call-next-method)))

(defun %lock-package-family! (root-package root-name)
  "Lock ROOT-PACKAGE and every loaded dot/slash-named implementation package."
  (unless (find-package root-package)
    (error "Required package ~A is unavailable." root-name))
  (let ((prefix-length (length root-name)))
    (dolist (package (list-all-packages))
      (let ((name (package-name package)))
        (when (and (>= (length name) prefix-length)
                   (string-equal root-name name :end2 prefix-length)
                   (or (= (length name) prefix-length)
                       (member (char name prefix-length) '(#\. #\/))))
          (sb-ext:lock-package package)
          (unless (sb-ext:package-locked-p package)
            (error "Package ~A could not be locked." name))))))
  t)

(defun %ensure-jzon-package-locked! ()
  "Lock Jzon's public package and loaded implementation package family."
  (%lock-package-family! :com.inuoe.jzon "COM.INUOE.JZON"))

(defun %ensure-dexador-package-locked! ()
  "Lock Dexador's public package and loaded implementation package family."
  (%lock-package-family! :dexador "DEXADOR"))

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

(defparameter *prefilter-denylist*
  '(;; SPEC-012 CON-002 table
    (unintern                        . :unintern)
    (delete-package                  . :delete-package)
    (sb-ext:save-lisp-and-die        . :save-lisp-and-die)
    (sb-ext:exit                     . :exit)
    (sb-ext:quit                     . :quit)
    (sb-ext:without-package-locks    . :without-package-locks)
    (sb-ext:unlock-package           . :unlock-package)
    (sb-sys:without-interrupts       . :interrupt-suppression)
    ;; Direct environment and child-process access can disclose provider
    ;; credentials before the provider's protected request path runs.
    (uiop:getenv                     . :environment-access)
    (uiop:getenvp                    . :environment-access)
    (uiop:getenv-pathname            . :environment-access)
    (uiop:getenv-pathnames           . :environment-access)
    (uiop:getenv-absolute-directory  . :environment-access)
    (uiop:getenv-absolute-directories . :environment-access)
    (sb-ext:posix-getenv             . :environment-access)
    (sb-ext:posix-environ            . :environment-access)
    (sb-posix:getenv                 . :environment-access)
    (sb-posix:putenv                 . :environment-access)
    (sb-posix:setenv                 . :environment-access)
    (sb-posix:unsetenv               . :environment-access)
    (sb-posix:fork                   . :process-launch)
    (uiop:run-program                . :process-launch)
    (uiop:launch-program             . :process-launch)
    (asdf:run-shell-command          . :process-launch)
    (sb-ext:run-program              . :process-launch)
    ;; ADR-012 §A1 — eval/load/read primitives at top level
    (eval                            . :eval-bypass)
    (compile                         . :compile-bypass)
    (compile-file                    . :compile-file-bypass)
    (load                            . :load-bypass)
    (read                            . :read-bypass)
    (read-from-string                . :read-from-string-bypass)
    (read-preserving-whitespace      . :read-bypass)
    ;; Reader-macro pollution (also in the safety layer, but cheap to catch
    ;; at the root too).
    (set-macro-character             . :reader-macro-pollution)
    (set-dispatch-macro-character    . :reader-macro-pollution)
    (set-syntax-from-char            . :reader-macro-pollution)
    ;; Thread interruption bypasses the evaluation worker boundary.
    (sb-thread:interrupt-thread      . :thread-interrupt)
    (sb-thread:terminate-thread      . :thread-terminate))
  "Top-level operator → rejection rule keyword. Every key is also folded
into *SAFETY-LAYER-SYMBOLS*, so burying an operator cannot bypass this gate.")

(defparameter *protected-runtime-definition-targets*
  '(make-instance allocate-instance initialize-instance reinitialize-instance
    shared-initialize change-class update-instance-for-different-class
    update-instance-for-redefined-class slot-missing slot-unbound
    compute-applicable-methods no-applicable-method no-next-method
    sb-mop:slot-value-using-class sb-mop:slot-boundp-using-class
    sb-mop:slot-makunbound-using-class
    sb-mop:compute-applicable-methods-using-classes)
  "Runtime protocols that evaluated code may call but may never extend.")

(defun %runtime-package-p (package)
  (when package
    (let ((name (package-name package)))
      (or (string= name "COMMON-LISP")
          (string= name "KEYWORD")
          (and (>= (length name) 3) (string= name "SB-" :end1 3 :end2 3))
          (and (>= (length name) 4) (string= name "UIOP" :end1 4 :end2 4))
          (and (>= (length name) 4) (string= name "ASDF" :end1 4 :end2 4))))))

(defun %protected-runtime-definition-target-p (name)
  (let ((base (cond
                ((symbolp name) name)
                ((and (%proper-list-p name) (= 2 (length name))
                      (eq (first name) 'setf) (symbolp (second name)))
                 (second name)))))
    (and base
         (not (safety-layer-symbol-p base))
         (or (member base *protected-runtime-definition-targets* :test #'eq)
             (%runtime-package-p (symbol-package base))))))

(defun %protected-runtime-definition-rejection (form)
  "Reject protected definitions and mutation forms anywhere in FORM's graph."
  (let ((pending (list form))
        (seen (make-hash-table :test #'eq)))
    (loop while pending
          for node = (pop pending)
          when (and (consp node) (not (gethash node seen)))
            do (setf (gethash node seen) t)
               (let ((head (car node)))
                 (let ((rule (and (symbolp head)
                                  (cdr (assoc head *prefilter-denylist*
                                              :test #'eq)))))
                   (when (member rule '(:environment-access :process-launch))
                     (return-from %protected-runtime-definition-rejection
                       (list :status :rejected :rule rule
                             :reason "Environment and process access is operator-only."))))
                 (cond
                   ((and (member head '(defmethod defgeneric defun defmacro)
                                 :test #'eq)
                         (consp (cdr node))
                         (%protected-runtime-definition-target-p (second node)))
                    (return
                      (list :status :rejected
                            :rule :runtime-protocol-redefinition
                            :reason
                            "Definitions of runtime/package protocols are operator-only.")))
                   ((member head '(setf psetf) :test #'eq)
                    (let ((result (%prefilter-setf node)))
                      (unless (eq result :pass) (return result))))
                   ((member head '(setq psetq) :test #'eq)
                    (let ((result (%prefilter-setq node)))
                      (unless (eq result :pass) (return result))))
                   ((member head '(set makunbound) :test #'eq)
                    (let ((result (%prefilter-symbol-mutator node)))
                      (unless (eq result :pass) (return result)))))
               (push (car node) pending)
               (push (cdr node) pending)))))

(defparameter *authorization-tcb-symbols*
  '(;; The recognizer, fact seam, proof gate, evaluator, and audit/rollback
    ;; pipeline.  Every named link is protected across sequential calls.
    *authorization-tcb-symbols*
    *safety-layer-symbols*
    *safety-layer-categories*
    safety-layer-symbol-p
    %symbol-category
    %category-rationale
    %derivation-trigger-symbol
    %vetoed-hint
    *prefilter-denylist*
    *protected-runtime-definition-targets*
    %runtime-package-p
    %protected-runtime-definition-target-p
    %protected-runtime-definition-rejection
    %prefilter-denylist-rule
    %harness-eval-prefilter
    %prefilter-setf
    %prefilter-setf-place
    %prefilter-setq
    %prefilter-symbol-mutator
    %symbol-eq
    %definition-function-name-p
    %defmethod-target-and-spec
    %spec-name-of-arg
    %lift-form
    *harness-eval-audit-log*
    %unicode-scalar-string-p
    %auditable-form-string
    %auditable-receipt-tree
    %form-fingerprint
    sb-md5:md5sum-sequence
    %tool-receipt!
    *redefine-history*
    *redefine-history-verbatim-cap*
    redefine-history
    last-redefinition
    all-redefined-symbols
    %record-definition!
    *rollback-register*
    rollback-records
    find-rollback-records-for
    %method-set
    %push-method-rollback!
    %push-function-rollback!
    %audit-rollback!
    %record-rollback-event!
    %rollback-method-record!
    %rollback-function-record!
    rollback!
    *harness-eval-result-truncate-bytes*
    *harness-eval-default-timeout-ms*
    *harness-eval-max-timeout-ms*
    *harness-eval-default-package*
    *harness-eval-maximum-source-characters*
    *harness-eval-maximum-reader-introducers*
    *harness-eval-maximum-reader-dispatch-argument*
    *harness-eval-maximum-form-nodes*
    *harness-eval-maximum-form-depth*
    *form-counter*
    *form-counter-lock*
    %next-form-id
    %bounded-prin1
    %bounded-princ
    %truncate-harness-eval-output
    %harness-eval-argument-plist-p
    %oversized-reader-dispatch-prefix-p
    %source-structure-rejection
    %parse-form-locked
    %form-structure-rejection
    %lift-facts
    %assert-lift-facts!
    %retract-lift-facts!
    %assert-safety-layer-facts!
    %query-forbidden
    %eval-form-with-timeout
    %elapsed-ms
    %form-rollback-prep
    %form-rollback-record
    %form-record-definition
    %harness-eval-handler
    %emit-receipt!
    %after-parse-pipeline
    %after-prefilter-pipeline
    %after-reasoner-pipeline
    ;; Reasoner proof production and validation used by the safety gate.
    *reasoner-ipc-call*
    load-theory
    query
    assert-fact!
    retract-fact!
    %proper-list-p
    *active-theory-handle*
    %proof-result-valid-p
    proof-result-positive-p
    invariant-filter-hook
    *invariant-filter-handle*
    install-invariant-filter!
    uninstall-invariant-filter!
    ;; Sync hook routing is part of the invariant-filter path.
    *hook-keys*
    *excluded-hook-keys*
    *hook-semantics*
    *hook-registry*
    *hook-registry-lock*
    register-hook
    remove-hook
    list-hooks
    clear-all-hooks
    run-hook
    ;; Registry normalization and the closure-owned dispatch ceiling.
    *valid-permissions*
    *valid-param-types*
    *tool-registry*
    *tool-registry-lock*
    *operator-tool-dispatch-p*
    %validate-tool-spec
    register-tool!
    unregister-tool!
    %normalize-tool-name
    find-tool
    list-tools
    clear-all-tools
    define-tool
    tool
    make-tool
    tool-name
    tool-description
    tool-permission
    tool-schema
    tool-handler
    %tool-name-equal-p
    %canonical-evaluation-tool-names
    %evaluation-authority-thread-key
    %call-with-evaluation-tool-authority
    %evaluation-tool-permitted-p
    %effective-agent-tool-names
    %authorized-agent-tool-name
    dispatch-tool!
    with-operator-tool-dispatch
    *current-agent*
    agent
    agent-id
    agent-tools
    sb-thread:*current-thread*
    sb-thread:current-thread-sap
    sb-sys:sap-int
    ;; Evaluation timeouts rely on asynchronous thread interruption. Literal
    ;; suppression forms and their dynamic state are therefore trusted.
    sb-sys:without-interrupts
    sb-sys:allow-with-interrupts
    sb-sys:with-interrupts
    sb-sys:with-local-interrupts
    sb-sys:with-interrupt-bindings
    sb-sys:in-interruption
    sb-sys:*interrupts-enabled*
    sb-sys:*allow-with-interrupts*
    sb-sys:*interrupt-pending*
    sb-thread:*interrupt-handler*
    sb-unix::*unblock-deferrables-on-enabling-interrupts-p*
    ;; Parser behavior must not inherit ambient debugger/reader state left by
    ;; an earlier worker.
    *break-on-signals*
    *read-suppress*
    *read-base*
    *read-default-float-format*
    *print-base*
    *print-radix*
    *print-case*
    *print-array*
    *print-gensym*
    *print-pretty*
    *print-readably*
    *print-circle*
    *print-length*
    *print-level*
    *print-escape*
    *package*
    ;; Every same-thread entry and helper that can reach dispatch.
    process-turn
    *max-tool-use-iterations*
    *invalid-tool-arguments-marker*
    %invalid-tool-arguments-p
    %consume-stream
    %dispatch-tool-use
    drive-stream
    handle-tool-frame
    provider-stream!
    stream-next-frame!
    tool-results-message-content
    agent-provider
    agent-message-history
    ;; Provider construction, request metadata, credentials, and clean-image
    ;; erasure are one sequential authority boundary.  A broad :AROUND method
    ;; on an endpoint reader must not be able to redirect a later request while
    ;; retaining the real Authorization header; nor may an evaluated form turn
    ;; a later :CLEAN image save into a secret-bearing image.
    auth-headers
    build-request
    anthropic-provider
    make-anthropic-provider
    anthropic-api-key
    anthropic-model
    anthropic-base-url
    anthropic-max-tokens
    anthropic-version
    anthropic-clear-credentials!
    openrouter-provider
    make-openrouter-provider
    openrouter-api-key
    openrouter-model
    openrouter-base-url
    openrouter-max-tokens
    openrouter-temperature
    openrouter-site-url
    openrouter-app-name
    openrouter-clear-credentials!
    uiop:getenv
    uiop:getenvp
    uiop:getenv-pathname
    uiop:getenv-pathnames
    uiop:getenv-absolute-directory
    uiop:getenv-absolute-directories
    sb-ext:posix-getenv
    sb-ext:posix-environ
    sb-posix:getenv
    sb-posix:putenv
    sb-posix:setenv
    sb-posix:unsetenv
    sb-posix:fork
    uiop:run-program
    uiop:launch-program
    asdf:run-shell-command
    sb-ext:run-program
    *clean-checklist*
    pre-save-clean!
    save-image!
    agent-identity
    identity-private-key
    clear-identity-private-key!
    register-identity-for-clean!
    %ht
    %param-key
    %type-string
    schema->json-schema
    json-schema->schema
    tool->anthropic-descriptor
    %schema-properties->ht
    %tool->anthropic-ht
    %tool->openai-ht
    %hash->plist
    %tool-describe-agent
    ;; Provider response ingress must stay coupled to its recognizer before a
    ;; frame can reach dispatch.  Protect both the built-in Anthropic chain and
    ;; the opt-in OpenRouter recognizer, including every mutable resource bound.
    dex:post
    dex:request
    #-windows dexador.backend.usocket:request
    #+windows dexador.backend.winhttp:request
    dex:*default-connect-timeout*
    dex:*default-read-timeout*
    dex:*default-proxy*
    dex:*verbose*
    dex:*not-verify-ssl*
    dex:*connection-pool*
    dex:*use-connection-pool*
    dex:*dexador-backend*
    #-windows dexador.backend.usocket:*ca-bundle*
    *anthropic-http-post*
    %anthropic-stop-reason-keyword
    %anthropic-response->frames
    %fetch-and-parse
    *openrouter-http-post*
    +openrouter-maximum-response-octets+
    +openrouter-maximum-argument-octets+
    +openrouter-maximum-json-depth+
    +openrouter-maximum-json-nodes+
    +openrouter-maximum-object-keys+
    +openrouter-maximum-array-elements+
    +openrouter-maximum-string-characters+
    +openrouter-maximum-tool-calls+
    +openrouter-maximum-identifier-characters+
    +openrouter-maximum-tool-name-characters+
    %openrouter-json-octet-length
    %openrouter-scan-json!
    %openrouter-parse-json
    %openrouter-hash-shape!
    %openrouter-token-string-p
    %openrouter-registered-tool
    %openrouter-argument-type-p
    %openrouter-recognize-tool-arguments
    %openai-args->plist
    %openrouter-finish-reason
    %openrouter-validate-token-details!
    %openrouter-validate-usage!
    %openrouter-validate-root-metadata!
    %openrouter-error-frames
    %openrouter-error-envelope-frames
    %openrouter-tool-call->frame
    %openrouter-response->frames
    %openrouter-bounded-response-string
    %openrouter-fetch-and-parse
    uiop:symbol-call
    ;; Jzon is an unlocked dependency. Its public parser/writer cells and the
    ;; constructor/closer emitted by WITH-PARSER are part of the same ingress
    ;; TCB as our wrappers.
    com.inuoe.jzon:parse
    com.inuoe.jzon:parse-next
    com.inuoe.jzon:with-parser
    com.inuoe.jzon:make-parser
    com.inuoe.jzon:close-parser
    com.inuoe.jzon:stringify
    %lock-package-family!
    %ensure-jzon-package-locked!
    %ensure-dexador-package-locked!
    sb-ext:lock-package
    sb-ext:package-locked-p
    sb-ext:unlock-package
    sb-ext:without-package-locks
    ;; Worker result transport is part of the cleanup-before-publication gate.
    mailbox
    make-mailbox
    mailbox-head
    mailbox-tail
    mailbox-count
    mailbox-closed
    mailbox-lock
    mailbox-cv
    send!
    receive!
    peek-mailbox
    mailbox-depth
    close-mailbox!
    sb-thread:with-mutex
    sb-thread:make-mutex
    sb-thread:make-waitqueue
    sb-thread:condition-wait
    sb-thread:condition-notify
    sb-thread:condition-broadcast
    print-object
    ;; Audit resources and the opt-in self-modification installer.
    receipt-log
    receipt-log-path
    %receipt-log-stream
    %receipt-log-seqs
    %receipt-log-lock
    +receipt-maximum-form-characters+
    +receipt-maximum-form-depth+
    +receipt-maximum-form-nodes+
    +receipt-maximum-token-characters+
    +receipt-maximum-string-characters+
    +receipt-maximum-summary-characters+
    +receipt-maximum-log-octets+
    +receipt-entry-keys+
    +receipt-general-entry-keys+
    +receipt-selfmod-entry-keys+
    +receipt-reader-symbol-tokens+
    +receipt-summary-keywords+
    %receipt-whitespace-p
    %receipt-unicode-scalar-character-p
    %receipt-simple-string
    %receipt-integer-token-p
    %receipt-token-allowed-p
    %read-receipt-source
    %proper-receipt-list-p
    %receipt-summary-plist-p
    %receipt-entry-keys-exact-p
    %receipt-entry-shape-p
    %receipt-entry-structure-p
    %reject-receipt-sharp-reader
    %read-receipt-locked
    %receipt-file-size
    %ensure-receipt-file-size!
    %write-receipt-entry!
    %recover-seqs!
    content-hash
    iso-8601-now
    *open-receipt-logs*
    *credential-erasers*
    register-receipt-log-for-clean!
    register-credential-eraser!
    append-receipt!
    read-receipts
    open-receipt-log
    close-receipt-log!
    *self-modification-tool-names*
    *harness-eval-audit-log-path*
    *harness-eval-description*
    %ensure-anuna-imago-user-package
    %fmt-symbol-with-package
    %tool-list-safety-layer
    %tool-redefine-history
    %rollback-record-summary
    %tool-list-rollbacks
    %tool-rollback
    %tool-query-self-mod-receipts
    %register-self-mod-introspection-tools!
    install-self-modification-tools!
    uninstall-self-modification-tools!
    harness-eval)
  "Named trusted-computing-base surface protected from harness evaluation.")

(defparameter *safety-layer-symbols*
  (remove-duplicates
   (append
    *authorization-tcb-symbols*
    ;; Structural top-level rejects also need a reasoner-floor counterpart
    ;; when the same operator is buried inside another form.
    (mapcar #'car *prefilter-denylist*)
    '(;; Legacy generic retained by the SPEC-012 floor theory.
      tool-call
      ;; ADR-012 §A1 — eval/load/read primitives
      eval compile compile-file load read read-from-string
      read-preserving-whitespace
      ;; reader-macro primitives
      set-macro-character set-dispatch-macro-character set-syntax-from-char
      *readtable* copy-readtable make-dispatch-macro-character
      ;; Special-variable mutators and binding machinery.
      set makunbound progv
      ;; Thread primitives that bypass eval-thread isolation.
      sb-thread:interrupt-thread sb-thread:terminate-thread
      sb-thread:make-thread sb-thread:join-thread
      ;; Method/class introspection and mutation.
      add-method remove-method find-method ensure-generic-function
      sb-mop:generic-function-methods sb-mop:intern-eql-specializer))
   :test #'eq)
  "Symbols treated as untouchable by the floor invariants. Mention any of
these in a form's free-symbols and the reasoner returns +Δ via the
generalised mentions/2 rule. ADR-012 §A1.")

(defun safety-layer-symbol-p (sym)
  "T if SYM is in the safety-layer set."
  (and (symbolp sym) (member sym *safety-layer-symbols* :test #'eq)))

;; ---------------------------------------------------------------- categories
;;
;; Symbols in *safety-layer-symbols* are grouped into categories so the
;; reasoner-veto handler can emit a teaching :hint instead of just naming
;; the offending symbol. Without categorisation, the agent treats each
;; veto as "this specific symbol is bad" and cycles through alternatives
;; from the same category one at a time (eval → read → load → … each
;; producing the same +Δ). The hint says "this entire category is
;; forbidden; here's an alternative class of tools".

(defparameter *safety-layer-categories*
  `((:authorization-tcb
     ,*authorization-tcb-symbols*
     "Named enforcement and dispatch functions, variables, accessors, and entry points form one trusted computing base. Redefining any named link could weaken a later harness-eval call, so the entire group is operator-only.")
    (:eval-class
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
      %harness-eval-prefilter %harness-eval-handler tool-call handle-tool-frame
      dispatch-tool! %authorized-agent-tool-name
      %call-with-evaluation-tool-authority %evaluation-tool-permitted-p
      register-tool! unregister-tool! %tool-receipt!)
     "Safety-stack functions and generics themselves. Redefining them would defeat the safety stack. Cannot be added to or replaced from inside harness-eval — operator action at the REPL is the only path.")
    (:dispatch-authority-state
     (*current-agent* *operator-tool-dispatch-p* with-operator-tool-dispatch
      progv)
     "Dispatch authority state. Evaluated code retains its calling agent and cannot create operator scope or dynamically replace either authority binding.")
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
  "Groups *safety-layer-symbols* into twelve categories. Entries may overlap.
Each entry is
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
  (unless (%form-structure-rejection derivation)
    (loop for clause in derivation
          when (and (%proper-list-p clause)
                    (member (first clause)
                            '(mentions defmethod-targets defgeneric-targets
                              defun-targets))
                    (>= (length clause) 3))
            return (third clause))))

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

(defun %prefilter-denylist-rule (op)
  (cdr (assoc op *prefilter-denylist* :test #'eq)))

(defun %harness-eval-prefilter (form)
  "Pre-filter per CON-002 + ADR-012 §A2/§A3/§A4. Returns :PASS or
  (:REJECTED :RULE <kw> :REASON <str>)."
  (let ((runtime-rejection (%protected-runtime-definition-rejection form)))
    (when runtime-rejection
      (return-from %harness-eval-prefilter runtime-rejection)))
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

         ;; Rollback capture calls FBOUNDP/FIND-METHOD before the worker. Keep
         ;; malformed method names from escaping the audited rejection path.
         ((and (eq op 'defmethod)
               (not (%definition-function-name-p
                     (and (consp (cdr form)) (second form)))))
          (list :status :rejected
                :rule :invalid-definition-target
                :reason
                "defmethod requires a symbol or exact (setf SYMBOL) name"))

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
;;   - every safety-layer symbol in any position.  This deliberately
;;     conservative rule catches special-variable bindings in LET, lambda
;;     lists, destructuring forms, and future binding macros without having
;;     to enumerate every Common Lisp binding construct.
;;   - every symbol that is the target of a buried defmethod/defgeneric/defun —
;;     so `(progn (defmethod tool-call …))` produces
;;       (:defmethod-targets (tool-call))
;;     and the reasoner can derive forbidden via defmethod-targets/2.

(defun %symbol-eq (a b)
  (and (symbolp a) (symbolp b) (eq a b)))

(defun %definition-function-name-p (name)
  "Recognize the function-name subset supported by rollback capture."
  (or (and name (symbolp name))
      (and (%proper-list-p name)
           (= 2 (length name))
           (eq (first name) 'setf)
           (symbolp (second name)))))

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
        (defn-tgts  (make-hash-table :test 'eq))
        (walked     (make-hash-table :test 'eq)))
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
                 ;; Safety authority/state names are significant even in
                 ;; value position.  In particular, a special variable in a
                 ;; lambda list or binding pattern is not a functional head.
                 ((symbolp x)
                  (when (safety-layer-symbol-p x)
                    (setf (gethash x free) t)))
                 ((and (arrayp x)
                       (not (stringp x))
                       (not (typep x 'bit-vector)))
                  (unless (gethash x walked)
                    (setf (gethash x walked) t)
                    (dotimes (index (array-total-size x))
                      (walk (row-major-aref x index)))))
                 ((not (consp x)) nil)
                 ((gethash x walked) nil)
                 (t
                  (setf (gethash x walked) t)
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
                      ((let let*)
                       ;; Binding a safety special is authority mutation just
                       ;; as surely as SETQ. Record every binding variable so
                       ;; the mentions/2 floor can distinguish safe locals.
                       (let ((bindings (and (consp (cdr x)) (second x))))
                         (when (listp bindings)
                           (dolist (binding bindings)
                             (let ((var (if (consp binding)
                                            (first binding)
                                            binding)))
                               (when (symbolp var)
                                 (setf (gethash var free) t)))))))
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
                    (walk (car x))
                    (walk (cdr x)))))))
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

(defun %unicode-scalar-string-p (value)
  "Whether VALUE is a string containing only Unicode scalar characters."
  (and (stringp value)
       (loop for character across value
             for code = (char-code character)
             always (and (<= code #x10FFFF)
                         (not (<= #xD800 code #xDFFF))))))

(defun %auditable-form-string (value)
  "Return VALUE when UTF-8 encodable, otherwise a stable ASCII placeholder."
  (if (%unicode-scalar-string-p value)
      (%receipt-simple-string value)
      "[INVALID-UNICODE-SOURCE]"))

(defun %auditable-receipt-tree (value)
  "Copy VALUE into the closed, acyclic data grammar used by receipt files.
Shared/cyclic edges and unsupported objects become explicit inert markers;
excessive evidence becomes one bounded omission marker rather than unreadable
printer abbreviations such as # or ...."
  (let ((seen (make-hash-table :test #'eq))
        (nodes 0)
        (characters 0))
    (labels ((charge (amount)
               (incf characters amount)
               (when (> characters +receipt-maximum-summary-characters+)
                 (error "Receipt summary exceeds the character budget.")))
             (safe-string (string)
               ;; Account for the worst case in CL string syntax, where every
               ;; source character needs a leading escape.
               (let ((safe (if (%unicode-scalar-string-p string)
                               string
                               "[INVALID-UNICODE-AUDIT-VALUE]")))
                 (charge (* 2 (length safe)))
                 (%receipt-simple-string safe)))
             (copy-value (item depth)
               (incf nodes)
               (when (or (> nodes +receipt-maximum-form-nodes+)
                         (> depth +receipt-maximum-form-depth+))
                 (error "Receipt summary exceeds structural bounds."))
               (typecase item
                 (null nil)
                 (cons
                  (charge 2)
                  (if (gethash item seen)
                      (list "AUDIT-REFERENCE" "OMITTED")
                      (progn
                        (setf (gethash item seen) t)
                        (cons (copy-value (car item) (1+ depth))
                              (copy-value (cdr item) depth)))))
                 (string
                  (cond
                    ((not (%unicode-scalar-string-p item))
                     "[INVALID-UNICODE-AUDIT-VALUE]")
                    ((<= (length item) +receipt-maximum-string-characters+)
                     (safe-string item))
                    (t "[OVERSIZED-AUDIT-STRING]")))
                 (symbol
                  (if (member item +receipt-summary-keywords+ :test #'eq)
                      (progn (charge 32) item)
                      (safe-string
                       (let ((package (symbol-package item)))
                         (cond
                           ((keywordp item)
                            (format nil ":~A" (symbol-name item)))
                           (package
                            (format nil "~A::~A" (package-name package)
                                    (symbol-name item)))
                           (t
                            (format nil "[UNINTERNED-SYMBOL:~A]"
                                    (symbol-name item))))))))
                 (integer
                  (if (<= (integer-length (abs item)) 256)
                      (progn (charge 80) item)
                      (safe-string "[OVERSIZED-AUDIT-INTEGER]")))
                 (character (safe-string (string item)))
                 (real (safe-string (%bounded-prin1 item)))
                 (t (safe-string
                     (format nil "[UNSUPPORTED-AUDIT-VALUE:~A]"
                             (type-of item)))))))
      (handler-case (copy-value value 0)
        (error () (list :message
                        "Audit summary omitted: structural bound."))))))

(defun %form-fingerprint (form-string)
  "MD5 content fingerprint of FORM-STRING for audit cross-references, not trust."
  (let ((bytes (sb-ext:string-to-octets
                (%auditable-form-string form-string)
                :external-format :utf-8)))
    (%receipt-simple-string
     (with-output-to-string (s)
       (loop for b across (sb-md5:md5sum-sequence bytes)
             do (format s "~(~2,'0x~)" b))))))

(defun %tool-receipt! (log &key tool agent-id form result-phase result-tag
                                elapsed-ms result-summary)
  "Append a CON-004 entry to LOG. Valid Unicode FORM text is preserved
verbatim; invalid source is replaced by a stable ASCII audit placeholder.
Thread-safe via the underlying receipt-log mutex."
  (when log
    ;; Bind the complete printer environment around entry construction too:
    ;; numeric/custom AGENT-ID rendering is persisted evidence, not merely UI.
    (let ((*print-pretty* nil) (*print-readably* t) (*print-circle* nil)
          (*print-length* nil) (*print-level* nil)
          (*print-base* 10) (*print-radix* nil) (*print-case* :upcase)
          (*print-array* t) (*print-gensym* t)
          (*package* (find-package :anuna-imago)))
      (sb-thread:with-mutex ((%receipt-log-lock log))
        (let* ((raw-form (%auditable-form-string (or form "")))
               (safe-form
                 (if (<= (length raw-form)
                         +receipt-maximum-string-characters+)
                     raw-form
                     (%receipt-simple-string
                      (format nil "[OVERSIZED-SOURCE:~A]"
                              (%form-fingerprint raw-form)))))
               (summary-input
                 (if (%receipt-summary-plist-p result-summary)
                     result-summary
                     (list :message
                           "Audit summary omitted: invalid plist.")))
               (entry (list :tool
                            (if (and (symbolp tool)
                                     (string-equal (symbol-name tool)
                                                   "HARNESS-EVAL"))
                                'harness-eval
                                tool)
                            :agent-id
                            (%auditable-form-string
                             (princ-to-string (or agent-id "?")))
                            :timestamp (iso-8601-now)
                            :form safe-form
                            :form-hash (and form (%form-fingerprint safe-form))
                            :result-phase result-phase
                            :result-tag result-tag
                            :elapsed-ms elapsed-ms
                            :result-summary
                            (%auditable-receipt-tree summary-input)))
               (stream (%receipt-log-stream log)))
          (when stream
            (%write-receipt-entry! log entry))
          entry)))))

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
  (let* ((bytes (length (sb-ext:string-to-octets
                         form-string :external-format :utf-8)))
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
(defparameter *harness-eval-maximum-source-characters* 65536)
(defparameter *harness-eval-maximum-reader-introducers* 256)
(defparameter *harness-eval-maximum-reader-dispatch-argument* 8192)
(defparameter *harness-eval-maximum-form-nodes* 8192)
(defparameter *harness-eval-maximum-form-depth* 256)

(defvar *form-counter* 0)
(defvar *form-counter-lock* (sb-thread:make-mutex :name "form-counter"))

(defun %next-form-id ()
  (sb-thread:with-mutex (*form-counter-lock*)
    (incf *form-counter*)
    (intern (format nil "FORM-~D" *form-counter*) :keyword)))

(defun %truncate-harness-eval-output (string)
  "Return STRING within the configured UTF-8 octet cap, marking truncation."
  (labels ((utf8-prefix (octets limit)
             (let ((end (min limit (length octets))))
               ;; A UTF-8 continuation octet cannot begin a decoded suffix.
               ;; Back up to the leading octet when LIMIT splits a codepoint.
               (loop while (and (plusp end)
                                (< end (length octets))
                                (= #x80 (logand #xC0 (aref octets end))))
                     do (decf end))
               (sb-ext:octets-to-string octets :external-format :utf-8
                                                :end end))))
    (let* ((limit *harness-eval-result-truncate-bytes*)
           (octets (sb-ext:string-to-octets string :external-format :utf-8)))
      (cond
        ((<= (length octets) limit) string)
        (t
         (let* ((marker "…[TRUNCATED]")
                (marker-octets
                  (sb-ext:string-to-octets marker :external-format :utf-8)))
           (if (<= limit (length marker-octets))
               (utf8-prefix marker-octets limit)
               (concatenate
                'string
                (utf8-prefix octets (- limit (length marker-octets)))
                marker))))))))

(defun %bounded-prin1 (value)
  "Per ADR-013 OQ-003: bound the printer + truncate at *harness-eval-result-truncate-bytes*."
  (let* ((s (let ((*print-circle* t)
                  (*print-length* 100)
                  (*print-level* 10)
                  (*print-pretty* nil)
                  (*print-readably* nil)
                  (*print-base* 10)
                  (*print-radix* nil)
                  (*print-case* :upcase)
                  (*print-array* t)
                  (*print-gensym* t))
              (with-output-to-string (out) (prin1 value out)))))
    (%truncate-harness-eval-output s)))

(defun %bounded-princ (value)
  "Render VALUE for a human-facing message under the harness result cap."
  (let* ((s (let ((*print-circle* t)
                  (*print-length* 100)
                  (*print-level* 10)
                  (*print-pretty* nil)
                  (*print-readably* nil)
                  (*print-base* 10)
                  (*print-radix* nil)
                  (*print-case* :upcase)
                  (*print-array* t)
                  (*print-gensym* t))
              (with-output-to-string (out) (princ value out)))))
    (%truncate-harness-eval-output s)))

(defun %harness-eval-argument-plist-p (args)
  "Recognize a finite proper even-length argument plist before any GETF."
  (and (%proper-list-p args)
       (evenp (length args))))

(defun %oversized-reader-dispatch-prefix-p (source hash-index)
  "Whether # at HASH-INDEX has a decimal argument above the reader bound.
Accumulate only while the value is known to fit the configured small bound;
never call PARSE-INTEGER or construct an attacker-sized bignum."
  (let ((value 0)
        (index (1+ hash-index))
        (length (length source)))
    (loop while (< index length)
          for digit = (digit-char-p (char source index) 10)
          while digit
          do (when (> value
                      (floor (- *harness-eval-maximum-reader-dispatch-argument*
                                digit)
                             10))
               (return t))
             (setf value (+ (* value 10) digit))
             (incf index)
          finally (return nil))))

(defun %source-structure-rejection (source)
  "Bound recursive reader syntax before READ-FROM-STRING can consume SOURCE.
Counting introducers inside strings/comments is an intentional conservative
false denial: the gate must be iterative and independent of reader recursion."
  (cond
    ((not (%unicode-scalar-string-p source))
     (list :status :rejected
           :rule :invalid-source-character
           :reason "The source contains a non-Unicode-scalar character."))
    ((> (length source) *harness-eval-maximum-source-characters*)
     (list :status :rejected
           :rule :source-too-large
           :reason "The source exceeds the character limit."))
    (t
     (let ((introducers 0))
       (loop for index below (length source)
             for character = (char source index)
             for code = (char-code character)
             when (= code 35)
               do (let ((dispatch-index (1+ index)))
                    (loop while (and (< dispatch-index (length source))
                                     (digit-char-p
                                      (char source dispatch-index) 10))
                          do (incf dispatch-index))
                    (when (< dispatch-index (length source))
                      (case (char-upcase (char source dispatch-index))
                        (#\S
                         (return-from %source-structure-rejection
                           (list
                            :status :rejected
                            :rule :reader-structure-literal
                            :reason
                            "Structure reader dispatch is not accepted.")))
                        (#\A
                         (return-from %source-structure-rejection
                           (list
                            :status :rejected
                            :rule :reader-array-literal
                            :reason
                            "Array reader dispatch is not accepted.")))
                        ((#\+ #\- #\= #\#)
                         (return-from %source-structure-rejection
                           (list
                            :status :rejected
                            :rule :recursive-reader-dispatch
                            :reason
                            "Recursive reader dispatch is not accepted."))))))
             when (and (= code 35)
                       (%oversized-reader-dispatch-prefix-p source index))
               do (return-from %source-structure-rejection
                    (list
                     :status :rejected
                     :rule :reader-dispatch-argument-too-large
                     :reason
                     "The source exceeds the numeric reader-dispatch limit."))
             when (member code '(40 39 96 44 35))
               do (when (> (incf introducers)
                           *harness-eval-maximum-reader-introducers*)
                    (return-from %source-structure-rejection
                      (list
                       :status :rejected
                       :rule :reader-structure-too-deep
                       :reason
                       "The source exceeds the recursive reader-syntax limit."))))))))

(defun %form-structure-rejection (form)
  "Return a rejection plist for an unsafe source/proof cons graph, else NIL.
The iterative grey/black walk accepts shared acyclic structure, rejects cycles
and bounds unique nodes and cons depth before recursive prefilter or lift code
observes the graph. A second pass rejects improper expression tails while
permitting acyclic dotted data beneath QUOTE."
  (let ((states (make-hash-table :test #'eq))
        (stack (list (list :enter form 0)))
        (nodes 0)
        (array-elements 0))
    (labels ((rejection (rule reason)
               (list :status :rejected :rule rule :reason reason))
             (array-container-p (value)
               (and (arrayp value)
                    (not (stringp value))
                    (not (typep value 'bit-vector)))))
      (loop while stack
            for item = (pop stack)
            for action = (first item)
            for node = (second item)
            for depth = (third item)
            do (cond
                 ((eq action :leave)
                  (setf (gethash node states) :done))
                 ((> depth *harness-eval-maximum-form-depth*)
                  (return-from %form-structure-rejection
                    (rejection
                     :form-too-deep
                     "The parsed form exceeds the structural depth limit.")))
                 ((consp node)
                  (case (gethash node states)
                    (:active
                     (return-from %form-structure-rejection
                       (rejection
                        :cyclic-form
                        "The parsed form contains a cyclic cons graph.")))
                    (:done nil)
                    (otherwise
                     (when (> (incf nodes)
                              *harness-eval-maximum-form-nodes*)
                       (return-from %form-structure-rejection
                         (rejection
                          :form-too-large
                          "The parsed form exceeds the structural node limit.")))
                     (setf (gethash node states) :active)
                     (push (list :leave node depth) stack)
                     ;; The CDR is the current list spine, not an additional
                     ;; expression nesting level. Nested elements in the CAR
                     ;; still increase depth.
                     (push (list :enter (cdr node) depth) stack)
                     (push (list :enter (car node) (1+ depth)) stack))))
                 ((typep node 'bit-vector)
                  (when (or (> (incf nodes)
                               *harness-eval-maximum-form-nodes*)
                            (> (incf array-elements (length node))
                               *harness-eval-maximum-form-nodes*))
                    (return-from %form-structure-rejection
                      (rejection
                       :form-too-large
                       "The parsed form exceeds the structural node limit."))))
                 ((array-container-p node)
                  (case (gethash node states)
                    (:active
                     (return-from %form-structure-rejection
                       (rejection
                        :cyclic-form
                        "The parsed form contains a cyclic array graph.")))
                    (:done nil)
                    (otherwise
                     (when (or (> (incf nodes)
                                  *harness-eval-maximum-form-nodes*)
                               (> (incf array-elements
                                        (array-total-size node))
                                  *harness-eval-maximum-form-nodes*))
                       (return-from %form-structure-rejection
                         (rejection
                          :form-too-large
                          "The parsed form exceeds the structural node limit.")))
                     (setf (gethash node states) :active)
                     (push (list :leave node depth) stack)
                     (dotimes (index (array-total-size node))
                       (push (list :enter (row-major-aref node index)
                                   (1+ depth))
                             stack)))))
                 ((typep node 'structure-object)
                  (return-from %form-structure-rejection
                    (rejection
                     :unsupported-form-object
                     "Structure literals are not accepted in evaluated source.")))
                 ((stringp node)
                  (unless (and (%unicode-scalar-string-p node)
                               (<= (length node)
                                   *harness-eval-maximum-source-characters*))
                    (return-from %form-structure-rejection
                      (rejection
                       :unsupported-form-object
                       "The parsed form contains an invalid or oversized string."))))
                 ((symbolp node)
                  (unless (and (%unicode-scalar-string-p (symbol-name node))
                               (<= (length (symbol-name node))
                                   *harness-eval-maximum-source-characters*))
                    (return-from %form-structure-rejection
                      (rejection
                       :unsupported-form-object
                       "The parsed form contains an invalid or oversized symbol."))))
                 (t nil)))
      (let ((pending (list form))
            (checked (make-hash-table :test #'eq)))
        (loop while pending
              for expression = (pop pending)
              when (and (consp expression)
                        (not (gethash expression checked)))
                do (setf (gethash expression checked) t)
                   (unless (%proper-list-p expression)
                     (return-from %form-structure-rejection
                       (rejection
                        :improper-form
                        "The parsed form contains an improper expression tail.")))
                   ;; QUOTE's operand is data. The graph pass above still
                   ;; checks it for cycles and bounds, while %LIFT-FORM still
                   ;; records protected literal symbols conservatively.
                   (unless (eq (car expression) 'quote)
                     (when (consp (car expression))
                       (push (car expression) pending))
                     (dolist (argument (cdr expression))
                       (when (consp argument)
                         (push argument pending)))))))
      nil))

(defun %parse-form-locked (form-string &optional package-name)
  "ADR-012 §A2 — read FORM-STRING with a pristine readtable and *read-eval* nil.
Returns (values form parse-error-or-nil)."
  (handler-case
      (let ((*readtable* (copy-readtable nil))
            (*read-eval* nil)
            (*read-suppress* nil)
            (*read-base* 10)
            (*read-default-float-format* 'single-float)
            (*break-on-signals* nil)
            (*package* (or (and package-name (find-package package-name))
                           (find-package :cl-user))))
        (values (read-from-string form-string) nil))
    (error (c) (values nil c))))

(defun %lift-facts (form-id lift)
  "Return every per-call reasoner fact for FORM-ID in stable assertion order."
  (append
   (list (list 'operator-of form-id (getf lift :operator)))
   (when (getf lift :target)
     (list (list 'operator-target form-id (getf lift :target))))
   (mapcar (lambda (target) (list 'defmethod-targets form-id target))
           (getf lift :defmethod-targets))
   (mapcar (lambda (target) (list 'defgeneric-targets form-id target))
           (getf lift :defgeneric-targets))
   (mapcar (lambda (target) (list 'defun-targets form-id target))
           (getf lift :defun-targets))
   (mapcar (lambda (symbol) (list 'mentions form-id symbol))
           (getf lift :free-symbols))))

(defun %assert-lift-facts! (handle form-id lift)
  "Assert all per-call facts. Return success and the first condition.

An assertion failure retracts the successfully asserted prefix on a best-effort
basis.  Callers must treat a false first value as a reasoner veto."
  (let ((asserted nil))
    (handler-case
        (progn
          (dolist (fact (%lift-facts form-id lift))
            (assert-fact! handle fact)
            (push fact asserted))
          (values t nil))
      (error (condition)
        (dolist (fact asserted)
          (ignore-errors (retract-fact! handle fact)))
        (values nil condition)))))

(defun %retract-lift-facts! (handle form-id lift)
  "Retract all per-call facts. Return success and the first condition."
  (let ((first-error nil))
    (dolist (fact (%lift-facts form-id lift))
      (handler-case (retract-fact! handle fact)
        (error (condition)
          (unless first-error (setf first-error condition)))))
    (values (null first-error) first-error)))

(defun %assert-safety-layer-facts! (handle)
  "Install one (safety-layer-symbol S) fact per element of
*safety-layer-symbols*. Called by INSTALL-SELF-MODIFICATION-TOOLS! after
load-theory and before the first harness-eval call."
  (let ((asserted nil))
    (handler-case
        (progn
          (dolist (symbol *safety-layer-symbols*)
            (let ((fact (list 'safety-layer-symbol symbol)))
              (assert-fact! handle fact)
              (push fact asserted)))
          t)
      (error (condition)
        (dolist (fact asserted)
          (ignore-errors (retract-fact! handle fact)))
        (error condition)))))

(defun %query-forbidden (handle form-id)
  "Return the proof-result plist, or NIL when the reasoner query fails."
  (handler-case (query handle (list 'forbidden 'eval-call form-id))
    (error () nil)))

(defun %eval-form-with-timeout (form package-name timeout-ms)
  "Evaluate FORM in PACKAGE-NAME under TIMEOUT-MS. Returns one of:
  (list :ok <bounded-value-string> <stdout-string> <elapsed-ms>)
  (list :error <condition-type> <message-string> <stdout-string> <elapsed-ms>)
  :timeout"
  (let* ((mb       (make-mailbox))
         (nonce    (gensym "EVALUATION-RESULT-"))
         (start    (get-internal-real-time))
         (pkg      (or (find-package package-name)
                       (find-package :cl-user)))
         (originating-agent *current-agent*)
         (originating-tools
           (and originating-agent
                (agent-tools originating-agent)))
         (worker
           (sb-thread:make-thread
            (lambda ()
              (let ((result
                      (handler-case
                          (%call-with-evaluation-tool-authority
                           originating-agent
                           originating-tools
                           (lambda ()
                             (let ((buf (make-string-output-stream)))
                               (handler-case
                                   (let ((*package* pkg)
                                         (*standard-output* buf)
                                         (*current-agent* originating-agent)
                                         (*operator-tool-dispatch-p* nil))
                                     (list :ok (%bounded-prin1 (eval form))
                                           (get-output-stream-string buf)
                                           (%elapsed-ms start)))
                                 (error (c)
                                   (list
                                    :error
                                    (type-of c)
                                    (handler-case (%bounded-princ c)
                                      (error ()
                                        "Unprintable evaluation condition."))
                                    (get-output-stream-string buf)
                                    (%elapsed-ms start)))))))
                        (error (c)
                          (list :error (type-of c)
                                "Evaluation worker failed closed."
                                "" (%elapsed-ms start))))))
                ;; Publish only after the authority cleanup has sanitized the
                ;; visible agent slot and removed the active thread ceiling.
                (handler-case (send! mb (cons nonce result))
                  (error () nil))))
            :name "harness-eval-worker"))
         (wire-reply
           (receive! mb :timeout (/ (max 1 timeout-ms) 1000.0))))
    (cond
      ((eq wire-reply :timeout)
       (handler-case (sb-thread:terminate-thread worker) (error () nil))
       (handler-case
           (sb-thread:join-thread worker :timeout 0.05 :default :still-running)
         (error () nil))
       :timeout)
      ((and (consp wire-reply) (eq nonce (first wire-reply)))
       (rest wire-reply))
      (t
       (handler-case (sb-thread:terminate-thread worker) (error () nil))
       (handler-case
           (sb-thread:join-thread worker :timeout 0.05 :default :still-running)
         (error () nil))
       (list :error 'invalid-worker-transport
             "Evaluation worker transport failed closed."
             "" (%elapsed-ms start))))))

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
  (let ((agent-id (when *current-agent* (agent-id *current-agent*)))
        (start (get-internal-real-time)))
    (cond
      ((not (%harness-eval-argument-plist-p args))
       (let* ((elapsed (%elapsed-ms start))
              (res (list :status :error :phase :evaluation
                         :condition-type 'invalid-argument
                         :message "arguments must be a finite proper even-length plist"
                         :elapsed-ms elapsed)))
         (%emit-receipt! 'harness-eval agent-id "" :evaluation :error elapsed
                         (list :condition-type 'invalid-argument
                               :message
                               "arguments must be a finite proper even-length plist"))
         res))

      (t
       (let* ((form-string (getf args :form))
              (pkg-arg (getf args :package))
              (pkg-name
                (cond
                  ((null pkg-arg) *harness-eval-default-package*)
                  ((stringp pkg-arg)
                   (string-upcase pkg-arg))
                  ((symbolp pkg-arg)
                   (symbol-name pkg-arg))
                  (t *harness-eval-default-package*)))
              (timeout-arg (getf args :timeout)))
         (cond
           ((or (null form-string) (not (stringp form-string)))
            (let* ((elapsed (%elapsed-ms start))
                   (res (list :status :error :phase :evaluation
                              :condition-type 'invalid-argument
                              :message ":form must be a non-empty string"
                              :elapsed-ms elapsed)))
              (%emit-receipt! 'harness-eval agent-id ""
                              :evaluation :error elapsed
                              (list :condition-type 'invalid-argument
                                    :message ":form must be a non-empty string"))
              res))

           ((and timeout-arg (not (integerp timeout-arg)))
            (let* ((elapsed (%elapsed-ms start))
                   (res (list :status :error :phase :evaluation
                              :condition-type 'invalid-argument
                              :message ":timeout must be an integer"
                              :elapsed-ms elapsed)))
              (%emit-receipt! 'harness-eval agent-id form-string
                              :evaluation :error elapsed
                              (list :condition-type 'invalid-argument
                                    :message ":timeout must be an integer"))
              res))

           (t
            (let ((source-rejection
                    (%source-structure-rejection form-string)))
              (cond
                (source-rejection
                 (let ((rule (getf source-rejection :rule))
                       (reason (getf source-rejection :reason)))
                   (%emit-receipt! 'harness-eval agent-id form-string
                                   :pre-filter :rejected (%elapsed-ms start)
                                   (list :rule rule :reason reason))
                   (list :status :rejected :phase :pre-filter
                         :rule rule :reason reason)))

                (t
                 (let ((timeout-ms
                         (max 1 (min *harness-eval-max-timeout-ms*
                                     (or timeout-arg
                                         *harness-eval-default-timeout-ms*)))))
                   (multiple-value-bind (form parse-err)
                       (%parse-form-locked form-string pkg-name)
                     (cond
                       (parse-err
                        (let* ((message (%bounded-princ parse-err))
                               (res
                                (list
                                 :status :error :phase :evaluation
                                 :condition-type 'parse-error
                                 :message message
                                 :elapsed-ms (%elapsed-ms start))))
                          (%emit-receipt!
                           'harness-eval agent-id form-string
                           :evaluation :error (%elapsed-ms start)
                           (list :condition-type 'parse-error
                                 :message message))
                          res))

                       (t
                        (%after-parse-pipeline
                         form form-string pkg-name timeout-ms
                         agent-id start)))))))))))))))

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
  (let ((pf (or (%form-structure-rejection form)
                (%harness-eval-prefilter form))))
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
       (multiple-value-bind (asserted-p assertion-error)
           (%assert-lift-facts! handle form-id lift)
         (let ((veto-result nil))
           (if (not asserted-p)
               (setf veto-result
                     (list :status :vetoed :phase :reasoner
                           :goal (list 'forbidden 'eval-call form-id)
                           :derivation '((reasoner-fact-assertion-failed))
                           :hint (%bounded-princ assertion-error)
                           :time-ms 0))
               (let ((proof (%query-forbidden handle form-id)))
                 (multiple-value-bind (retracted-p retraction-error)
                     (%retract-lift-facts! handle form-id lift)
                   (cond
                     ((not retracted-p)
                      (setf veto-result
                            (list :status :vetoed :phase :reasoner
                                  :goal (list 'forbidden 'eval-call form-id)
                                  :derivation '((reasoner-fact-retraction-failed))
                                  :hint (%bounded-princ retraction-error)
                                  :time-ms 0)))
                     ((or (not (%proof-result-valid-p proof))
                          (%form-structure-rejection
                           (getf proof :derivation)))
                      (setf veto-result
                            (list :status :vetoed :phase :reasoner
                                  :goal (list 'forbidden 'eval-call form-id)
                                  :derivation '((invalid-reasoner-evidence))
                                  :hint "Reasoner evidence was missing or malformed."
                                  :time-ms 0)))
                     ((proof-result-positive-p proof)
                      (let* ((derivation (getf proof :derivation))
                             (hint (%vetoed-hint derivation)))
                        (setf veto-result
                              (list :status :vetoed :phase :reasoner
                                    :goal (list 'forbidden 'eval-call form-id)
                                    :derivation derivation
                                    :hint hint
                                    :time-ms (or (getf proof :time-ms) 0)))))))))
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
                                       pkg-name timeout-ms agent-id)))))))))

(defun %after-reasoner-pipeline (form form-string lift form-id pkg-name timeout-ms agent-id)
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
         (let* ((condition-type (second reply))
                (message (third reply))
                (stdout (fourth reply))
                (elapsed (fifth reply))
                (res (list :status :error :phase :evaluation
                           :condition-type condition-type
                           :message message
                           :elapsed-ms elapsed
                           :stdout stdout)))
           (%emit-receipt! 'harness-eval agent-id form-string
                           :evaluation :error elapsed
                           (list :form-id form-id
                                 :condition-type condition-type
                                 :message message))
           res))
        (t   ; (:ok bounded-value-string stdout elapsed)
         (let* ((value (second reply))
                (stdout (third reply))
                (elapsed (fourth reply))
                (rollback-records (%form-rollback-record lift agent-id form-hash
                                                          pre-state))
                (res (list :status :ok :phase :evaluated
                           :value value
                           :stdout stdout
                           :elapsed-ms elapsed)))
           (%form-record-definition lift form-string agent-id rollback-records)
           (%emit-receipt! 'harness-eval agent-id form-string
                           :evaluated :ok elapsed
                           (list :form-id form-id
                                 :value-fingerprint
                                 (%form-fingerprint value)
                                 :rollback-indices
                                 (mapcar (lambda (r) (getf r :index))
                                         rollback-records)))
           res))))))
