;;;; examples/self-modifying.lisp — opt-in registration of harness-eval
;;;;
;;;; SPEC-012 REQ-001: this file is NOT loaded automatically. The harness
;;;; ships without the harness-eval tool registered. To opt the agent in,
;;;; the author must:
;;;;
;;;;   (load "examples/self-modifying.lisp")
;;;;   (let* ((theory-text (uiop:read-file-string "theories/self-modification-floor.spl"))
;;;;          (handle (load-theory theory-text)))
;;;;     (install-invariant-filter! :theory-handle handle)
;;;;     (install-self-modification-tools!))
;;;;
;;;; After these steps the agent has access to the harness-eval tool plus
;;;; five introspection tools (see *self-modification-tool-names*) subject
;;;; to the three-layer safety stack.

(in-package #:anuna-imago)

(defparameter *self-modification-tool-names*
  '(harness-eval
    harness-list-safety-layer
    harness-redefine-history
    harness-list-rollbacks
    harness-rollback
    harness-query-self-mod-receipts)
  "Tool names INSTALL-SELF-MODIFICATION-TOOLS! adds.")

(defparameter *harness-eval-audit-log-path*
  "/tmp/imago-harness-eval-audit.log"
  "Default path for the harness-eval audit log. Operators may rebind before
calling INSTALL-SELF-MODIFICATION-TOOLS!.")

(defun %ensure-anuna-imago-user-package ()
  "Create :anuna-imago-user if it does not exist; idempotent."
  (or (find-package :anuna-imago-user)
      (make-package :anuna-imago-user :use '(:cl :anuna-imago))))

;; ---------------------------------------------------------- harness-eval ---

(defparameter *harness-eval-description*
  "Submit a Common Lisp source form for evaluation in the harness's runtime
under the three-layer safety stack. NEVER raises — always returns a plist.

Args: :form (string, required), :package (string, default \"anuna-imago-user\"),
:timeout (int ms, 1..30000, default 1000).

Return shapes (one of):

  ; success
  (:status :ok       :phase :evaluated  :value <prin1-string>
                                        :stdout <string>
                                        :elapsed-ms <int>)
  ; pre-filter rejection — top-level operator on the structural denylist
  (:status :rejected :phase :pre-filter :rule <kw> :reason <str>)
  ; reasoner veto — form mentions a safety-layer symbol per the active theory
  (:status :vetoed   :phase :reasoner   :goal <list> :derivation <list>
                                        :hint <string>   ; READ THIS — names
                                                         ; the category and
                                                         ; suggests an
                                                         ; alternative class
                                                         ; of operations
                                        :time-ms <int>)
  ; runtime error during eval (form raised a condition)
  (:status :error    :phase :evaluation :condition-type <symbol>
                                        :message <string>
                                        :elapsed-ms <int>)
  ; eval exceeded :timeout — worker thread terminated
  (:status :timeout  :phase :evaluation :elapsed-ms <int>)

Forbidden surface: query (harness-list-safety-layer). Recent activity:
(harness-query-self-mod-receipts). Redefinition history per symbol:
(harness-redefine-history :symbol \"foo\"). Roll back a prior redefinition
by index: (harness-rollback :index N) — find indices via
(harness-list-rollbacks).

Forms run in the harness process with full heap access. The port is a
privilege escalation by design — operators retain authority via
unregister-tool! at the REPL.")

;; ---------------------------------------------- introspection: safety set ---

(defun %fmt-symbol-with-package (s)
  (format nil "~(~A:~A~)"
          (and (symbol-package s) (package-name (symbol-package s)))
          (symbol-name s)))

(defun %tool-list-safety-layer (args)
  "Return the safety-layer symbol set. Three modes:

  :by-category t      → categorised view: list of (:category :why
                        :symbols) plists. The agent should read this
                        first to learn what KINDS of operations are
                        forbidden — without categories, an agent that
                        gets vetoed on EVAL will retry with READ, then
                        LOAD, etc., not realising they're all in the
                        same forbidden class.
  :prefix \"FOO\"     → flat alphabetical list, filtered to symbols
                        whose name starts with FOO (case-insensitive).
  no args             → flat alphabetical list of all protected symbols."
  (let ((by-cat (getf args :by-category))
        (prefix (getf args :prefix)))
    (cond
      (by-cat
       (mapcar (lambda (entry)
                 (list :category (first entry)
                       :why      (third entry)
                       :symbols  (mapcar #'%fmt-symbol-with-package
                                          (second entry))))
               *safety-layer-categories*))
      (t
       (sort
        (loop for s in *safety-layer-symbols*
              for name = (symbol-name s)
              when (or (null prefix)
                       (and (stringp prefix)
                            (>= (length name) (length prefix))
                            (string-equal (subseq name 0 (length prefix))
                                          prefix)))
                collect (%fmt-symbol-with-package s))
        #'string<)))))

;; ---------------------------------------------- introspection: history ---

(defun %tool-redefine-history (args)
  "Return redefinition events. With :symbol, return events for that
symbol only; without, return one entry per redefined symbol with
:event-count + the most-recent event."
  (let* ((sym-name (getf args :symbol))
         (limit (or (getf args :limit) 10))
         (sym (and sym-name (find-symbol (string-upcase sym-name)
                                          :anuna-imago))))
    (cond
      (sym-name
       (cond
         ((null sym)
          (list :error :no-such-symbol
                :note (format nil "No symbol ~S in :anuna-imago" sym-name)))
         (t
          (let ((events (redefine-history sym)))
            (subseq events 0 (min limit (length events)))))))
      (t
       (loop for s in (all-redefined-symbols)
             collect (list :symbol (symbol-name s)
                           :event-count (length (redefine-history s))
                           :latest (first (redefine-history s))))))))

;; ---------------------------------------------- introspection: rollbacks ---

(defun %rollback-record-summary (rec)
  (list :index        (getf rec :index)
        :kind         (getf rec :kind)
        :symbol       (symbol-name (getf rec :symbol))
        :installed-at (getf rec :installed-at)
        :installed-by (let ((id (getf rec :installed-by)))
                        (and id (princ-to-string id)))
        :rolled-back  (getf rec :rolled-back)))

(defun %tool-list-rollbacks (args)
  "Lightweight summary of *rollback-register*. Optional :symbol filters."
  (let* ((sym-name (getf args :symbol))
         (sym (and sym-name (find-symbol (string-upcase sym-name)
                                          :anuna-imago)))
         (records (cond (sym (find-rollback-records-for sym))
                        (t   (rollback-records)))))
    (mapcar #'%rollback-record-summary records)))

(defun %tool-rollback (args)
  "Invoke (rollback! :index). Returns a status plist."
  (let ((index (getf args :index)))
    (cond
      ((not (integerp index))
       (list :error :invalid-index
             :note ":index must be a non-negative integer"))
      (t
       (let ((status (rollback! index)))
         (list :status status :index index))))))

;; ---------------------------------------------- introspection: receipts ---

(defun %tool-query-self-mod-receipts (args)
  "Return the most recent harness-eval audit-log entries. Distinct from
harness-query-receipts (which reads the SPEC-011 ASK/reply log)."
  (let ((limit (or (getf args :limit) 10)))
    (cond
      ((null *harness-eval-audit-log*)
       (list :error :no-audit-log
             :note "Self-modification tools not installed"))
      (t
       (let* ((path (receipt-log-path *harness-eval-audit-log*))
              (all (handler-case (read-receipts path) (error () nil))))
         (subseq all (max 0 (- (length all) limit))))))))

;; ---------------------------------------------- registration ---

(defun %register-self-mod-introspection-tools! ()
  (register-tool!
   (make-tool :name 'harness-list-safety-layer
              :description "Return the safety-layer symbol set — any form mentioning these will be rejected by the pre-filter or vetoed by the reasoner. Pass :by-category t (RECOMMENDED FIRST CALL) to get a categorised view with rationale per category — authorization-tcb, eval-class, reader-macro-class, thread-class, method-mutate-class, safety-layer-target, tool-struct, registry-table, audit-state, theory-state, harness-eval-state, harness-eval-install-fn. Without :by-category, returns a flat alphabetical list. Optional :prefix filters the flat list."
              :permission :read
              :schema '((:by-category :type :boolean :required-p nil
                         :description "Return categorised view with per-category rationale instead of flat list. Recommended for first call.")
                        (:prefix :type :string :required-p nil
                         :description "Filter the flat list to symbols whose name starts with this string (ignored when :by-category is true)."))
              :handler #'%tool-list-safety-layer))
  (register-tool!
   (make-tool :name 'harness-redefine-history
              :description "Query the symbol-origin index. Without :symbol, returns a per-symbol summary {:symbol :event-count :latest}. With :symbol, returns the most recent :limit events for that symbol (each event has :defining-form, :form-bytes, :agent-id, :timestamp, :prior-spec, :rollback-ref)."
              :permission :read
              :schema '((:symbol :type :string :required-p nil
                         :description "Symbol name to scope the query (looked up in :anuna-imago).")
                        (:limit  :type :integer :required-p nil
                         :description "Max events to return when :symbol given; default 10."))
              :handler #'%tool-redefine-history))
  (register-tool!
   (make-tool :name 'harness-list-rollbacks
              :description "Return a summary of *rollback-register*: each entry has :index, :kind (:method or :function), :symbol, :installed-at, :installed-by, :rolled-back. Use the :index value with harness-rollback. Optional :symbol filters to records targeting that symbol only."
              :permission :read
              :schema '((:symbol :type :string :required-p nil
                         :description "If given, only records targeting this symbol (looked up in :anuna-imago)."))
              :handler #'%tool-list-rollbacks))
  (register-tool!
   (make-tool :name 'harness-rollback
              :description "Re-install the prior method or symbol-function recorded at :index. Look up indices via harness-list-rollbacks. Returns {:status :ok|:no-such-record|:already-rolled-back :index N}. The rollback itself is audited (appears in the harness-eval audit log with :result-phase :rollback) and recorded in the origin index with :agent-id :rollback."
              :permission :execute
              :schema '((:index :type :integer :required-p t
                         :description "Index from harness-list-rollbacks."))
              :handler #'%tool-rollback))
  (register-tool!
   (make-tool :name 'harness-query-self-mod-receipts
              :description "Return the most recent harness-eval audit-log entries. Each entry has :tool, :agent-id, :timestamp, :form (verbatim source the agent submitted), :form-hash, :result-phase (:pre-filter | :reasoner | :evaluated | :rollback | :evaluation), :result-tag (:ok | :rejected | :vetoed | :error | :timeout), :elapsed-ms, :result-summary."
              :permission :read
              :schema '((:limit :type :integer :required-p nil
                         :description "Maximum entries; default 10."))
              :handler #'%tool-query-self-mod-receipts)))

;; ---------------------------------------------- main install / uninstall ---

(defun install-self-modification-tools! (&key (audit-log-path *harness-eval-audit-log-path*))
  "Register harness-eval and its five introspection siblings per CON-001 /
REQ-001 / REQ-009.

Pre-conditions:
  - *active-theory-handle* is non-nil (theory loaded via load-theory and
    installed via install-invariant-filter!).

Returns:
  :ok                — registered successfully
  :no-active-theory  — no theory installed; refusing
  :already-installed — harness-eval is already in the tool registry"
  (cond
    ((find-tool 'harness-eval)
     :already-installed)

    ((null *active-theory-handle*)
     :no-active-theory)

    (t
     ;; Establish the safety facts before exposing any eval permission, audit
     ;; resource, or tool.  A reasoner failure aborts installation unchanged.
     (%assert-safety-layer-facts! *active-theory-handle*)

     ;; Jzon is unlocked by its distribution. Seal its transitive parser
     ;; helpers before evaluated code becomes reachable.
     (%ensure-jzon-package-locked!)

     ;; 1. Permission keyword
     (pushnew :eval *valid-permissions*)

     ;; 2. Default eval package
     (%ensure-anuna-imago-user-package)

     ;; 3. Audit log — opens a separate receipt-log instance
     (unless *harness-eval-audit-log*
       (let ((log (open-receipt-log audit-log-path)))
         (setf *harness-eval-audit-log* log)
         (register-receipt-log-for-clean! log)))

     ;; 4. Register harness-eval itself
     (register-tool!
      (make-tool :name 'harness-eval
                 :description *harness-eval-description*
                 :permission :eval
                 :schema '((:form    :type :string  :required-p t
                            :description "The Common Lisp source form, as a UTF-8 string.")
                           (:package :type :string  :required-p nil
                            :description "Package name to read and evaluate the form in. Defaults to anuna-imago-user.")
                           (:timeout :type :integer :required-p nil
                            :description "Evaluation timeout in milliseconds (1..30000); default 1000."))
                 :handler #'%harness-eval-handler))

     ;; 5. Register the five introspection siblings
     (%register-self-mod-introspection-tools!)
     :ok)))

(defun uninstall-self-modification-tools! ()
  "Remove harness-eval + introspection siblings; close the audit log.
Idempotent."
  (dolist (name *self-modification-tool-names*)
    (unregister-tool! name))
  ;; Drop :eval from *valid-permissions* if no other tool uses it.
  (let ((still-used (loop for k being the hash-keys of *tool-registry*
                          for tool = (gethash k *tool-registry*)
                          when (eq (tool-permission tool) :eval)
                            return t)))
    (unless still-used
      (setf *valid-permissions*
            (remove :eval *valid-permissions*))))
  (when *harness-eval-audit-log*
    (handler-case (close-receipt-log! *harness-eval-audit-log*) (error () nil))
    (setf *open-receipt-logs* (remove *harness-eval-audit-log* *open-receipt-logs*))
    (setf *harness-eval-audit-log* nil))
  :ok)
