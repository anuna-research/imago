;;;; builtin-tools.lisp — small set of introspection / utility tools
;;;;
;;;; Auto-registered when (asdf:load-system :imago) loads. Agents that
;;;; want them must list the name(s) in :tools to expose to the LLM;
;;;; agents that don't list them are unaffected.
;;;;
;;;; Stance discipline: this file ships ONLY introspection + small
;;;; utility tools — nothing that augments capability with a frozen
;;;; abstraction. File ops live behind the opt-in INSTALL-FILEOPS-TOOLS!
;;;; (see fileops-tools.lisp). HTTP fetch, web search, and shell exec
;;;; are deliberately not built in — route those via MCP servers.

(in-package #:anuna-imago)

(defparameter *boot-time* (get-universal-time)
  "Universal time at harness load. Used for uptime in HARNESS-STATS.")

;; ---------------------------------------------------------- handlers ---

(defun %tool-list-tools (args)
  (declare (ignore args))
  (mapcar (lambda (s) (string-downcase (symbol-name s)))
          (list-tools)))

(defun %tool-describe-tool (args)
  (let* ((name (getf args :name))
         (sym  (and name (intern (string-upcase name) :anuna-imago)))
         (tool (and sym (find-tool sym))))
    (cond
      ((null tool)
       (list :name name :found nil))
      (t
       (list :name        (string-downcase (symbol-name (tool-name tool)))
             :found       t
             :description (tool-description tool)
             :permission  (tool-permission tool)
             :schema      (tool-schema tool))))))

(defun %tool-list-hooks (args)
  (declare (ignore args))
  (mapcar (lambda (entry)
            (list :key           (string-downcase (symbol-name (car entry)))
                  :handler-count (length (cdr entry))))
          (list-hooks)))

(defun %tool-version (args)
  (declare (ignore args))
  *version*)

(defun %tool-now (args)
  (declare (ignore args))
  (iso-8601-now))

(defun %tool-describe-agent (args)
  "Return the calling agent's metadata. Reads *CURRENT-AGENT*, which is
bound by PROCESS-TURN — so this only works during a turn. From the REPL
or a test, set *CURRENT-AGENT* manually."
  (declare (ignore args))
  (let ((a *current-agent*))
    (cond
      ((null a)
       (list :error :no-current-agent
             :note "harness-describe-agent only works during a turn (when *current-agent* is bound)"))
      (t
       (list :id            (princ-to-string (agent-id a))
             :capability    (agent-capability a)
             :system-prompt (agent-system-prompt a)
             :tools         (mapcar (lambda (s) (string-downcase (symbol-name s)))
                                    (agent-tools a))
             :state         (agent-state a))))))

(defun %tool-query-receipts (args)
  "Return the most recent receipt entries from the first registered log.
A receipt log becomes 'registered' via REGISTER-RECEIPT-LOG-FOR-CLEAN!;
agents without one get an :error :no-log result."
  (let ((limit (or (getf args :limit) 10)))
    (cond
      ((null *open-receipt-logs*)
       (list :error :no-log
             :note "No receipt log registered (call register-receipt-log-for-clean! first)"))
      (t
       (let* ((log (first *open-receipt-logs*))
              (path (receipt-log-path log))
              (all (read-receipts path)))
         (subseq all (max 0 (- (length all) limit))))))))

(defun %tool-uuid (args)
  "Return a fresh UUID v4 as a 36-char lowercase string."
  (declare (ignore args))
  (let ((bytes (make-array 16 :element-type '(unsigned-byte 8))))
    (loop for i from 0 below 16 do
      (setf (aref bytes i) (random 256)))
    ;; Set version (4) and variant (10) bits per RFC 4122 §4.4.
    (setf (aref bytes 6) (logior #x40 (logand (aref bytes 6) #x0F)))
    (setf (aref bytes 8) (logior #x80 (logand (aref bytes 8) #x3F)))
    (format nil "~(~2,'0x~2,'0x~2,'0x~2,'0x-~2,'0x~2,'0x-~2,'0x~2,'0x-~2,'0x~2,'0x-~2,'0x~2,'0x~2,'0x~2,'0x~2,'0x~2,'0x~)"
            (aref bytes 0) (aref bytes 1) (aref bytes 2) (aref bytes 3)
            (aref bytes 4) (aref bytes 5)
            (aref bytes 6) (aref bytes 7)
            (aref bytes 8) (aref bytes 9)
            (aref bytes 10) (aref bytes 11) (aref bytes 12) (aref bytes 13)
            (aref bytes 14) (aref bytes 15))))

(defun %tool-stats (args)
  "Process metrics: uptime, version, tool count, current agent's mailbox
depth + state when *CURRENT-AGENT* is bound."
  (declare (ignore args))
  (let ((a *current-agent*))
    (list :uptime-seconds (- (get-universal-time) *boot-time*)
          :version        *version*
          :tool-count     (length (list-tools))
          :mailbox-depth  (when a (mailbox-depth (agent-mailbox a)))
          :agent-state    (when a (agent-state a)))))

(defun %tool-query-theory (args)
  "Query the active Spindle theory with a goal string. Returns the
proof-result tag (+Δ, +∂, -Δ, -∂) and a :positive boolean. Does NOT
veto anything — this is for inspection only. Errors if no theory is
installed (call INSTALL-INVARIANT-FILTER! first)."
  (let ((goal-text (getf args :goal)))
    (cond
      ((null *active-theory-handle*)
       (list :error :no-theory
             :note "Install a theory via install-invariant-filter! :theory-handle …"))
      ((null goal-text)
       (list :error :missing-goal
             :note "Pass :goal as a string of an S-expression"))
      (t
       (handler-case
           (let* ((goal   (read-from-string goal-text))
                  (result (query *active-theory-handle* goal)))
             (list :tag      (getf result :tag)
                   :time-ms  (getf result :time-ms)
                   :positive (and (proof-result-positive-p result) t)))
         (error (c)
           (list :error :query-failed :detail (princ-to-string c))))))))

;; ---------------------------------------------------------- registration ---

(defun install-builtin-tools! ()
  "Register the built-in tools. Idempotent — safe to re-call after
CLEAR-ALL-TOOLS. Auto-called when this file loads."
  (register-tool!
   (make-tool :name 'harness-list-tools
              :description "List the names of all tools currently registered with the harness."
              :permission :read :schema () :handler #'%tool-list-tools))
  (register-tool!
   (make-tool :name 'harness-describe-tool
              :description "Return the description, permission, and schema of a registered tool by name."
              :permission :read
              :schema '((:name :type :string :required-p t
                         :description "Tool name as shown by harness-list-tools."))
              :handler #'%tool-describe-tool))
  (register-tool!
   (make-tool :name 'harness-list-hooks
              :description "List the registered hook keys and how many handlers each has."
              :permission :read :schema () :handler #'%tool-list-hooks))
  (register-tool!
   (make-tool :name 'harness-version
              :description "Return the harness version string (e.g. \"0.1.0\")."
              :permission :read :schema () :handler #'%tool-version))
  (register-tool!
   (make-tool :name 'harness-now
              :description "Return the current UTC time in ISO-8601 format."
              :permission :read :schema () :handler #'%tool-now))
  (register-tool!
   (make-tool :name 'harness-describe-agent
              :description "Return the calling agent's id, capability, system prompt, tool list, and state. Only works during a turn."
              :permission :read :schema () :handler #'%tool-describe-agent))
  (register-tool!
   (make-tool :name 'harness-query-receipts
              :description "Return the most recent receipt-log entries from the first registered receipt log."
              :permission :read
              :schema '((:limit :type :integer :required-p nil
                         :description "Maximum entries to return; default 10."))
              :handler #'%tool-query-receipts))
  (register-tool!
   (make-tool :name 'harness-uuid
              :description "Generate a fresh UUID v4 as a 36-character lowercase string."
              :permission :read :schema () :handler #'%tool-uuid))
  (register-tool!
   (make-tool :name 'harness-stats
              :description "Process metrics: uptime, version, tool count, current mailbox depth + agent state."
              :permission :read :schema () :handler #'%tool-stats))
  (register-tool!
   (make-tool :name 'harness-query-theory
              :description "Query the active Spindle theory with a goal. Returns the proof-result tag and a :positive boolean. Inspection only — does NOT veto."
              :permission :read
              :schema '((:goal :type :string :required-p t
                         :description "S-expression goal as a string, e.g. \"(forbidden delete-user)\"."))
              :handler #'%tool-query-theory)))

(defparameter *builtin-tool-names*
  '(harness-list-tools harness-describe-tool harness-list-hooks
    harness-version harness-now
    harness-describe-agent harness-query-receipts harness-uuid
    harness-stats harness-query-theory)
  "Names of all built-in tools. Convenience for agents that want them all:
  (make-instance 'agent ... :tools *builtin-tool-names*).")

;; Auto-register on file load.
(install-builtin-tools!)
