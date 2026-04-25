;;;; builtin-tools-tests.lisp — quality-gate tests for src/builtin-tools.lisp
;;;;
;;;; Each test calls INSTALL-BUILTIN-TOOLS! at the top so they remain
;;;; valid after other test suites that wipe the registry via
;;;; CLEAR-ALL-TOOLS.

(in-package #:anuna-imago.test)

(export 'run-builtin-tools-tests)

;; ----------------------------------------------- harness-list-tools ---

(defun test-builtin-list-tools ()
  (format t "~%-- builtin-list-tools --~%")
  (clear-all-tools)
  (install-builtin-tools!)
  (let ((result (dispatch-tool! 'harness-list-tools nil)))
    (check (listp result))
    (check (member "harness-list-tools" result :test #'string=)
           "self-listing — harness-list-tools is in its own output")
    (check (member "harness-now" result :test #'string=))
    (check (member "harness-version" result :test #'string=))))

;; ----------------------------------------------- harness-describe-tool ---

(defun test-builtin-describe-tool ()
  (format t "~%-- builtin-describe-tool --~%")
  (clear-all-tools)
  (install-builtin-tools!)
  (let ((result (dispatch-tool! 'harness-describe-tool '(:name "harness-now"))))
    (check (eq t (getf result :found)))
    (check (string= "harness-now" (getf result :name)))
    (check (eq :read (getf result :permission)))
    (check (search "ISO-8601" (getf result :description)))))

(defun test-builtin-describe-tool-missing ()
  (format t "~%-- builtin-describe-tool-missing --~%")
  (clear-all-tools)
  (install-builtin-tools!)
  (let ((result (dispatch-tool! 'harness-describe-tool '(:name "no-such-tool"))))
    (check (null (getf result :found)) "missing tool reports :found nil")))

;; ----------------------------------------------- harness-list-hooks ---

(defun test-builtin-list-hooks ()
  (format t "~%-- builtin-list-hooks --~%")
  (clear-all-tools) (clear-all-hooks)
  (install-builtin-tools!)
  (register-hook :on-user-input
                 (lambda (a v) (declare (ignore a)) v))
  (register-hook :on-user-input
                 (lambda (a v) (declare (ignore a)) v))
  (let ((result (dispatch-tool! 'harness-list-hooks nil)))
    (let ((entry (find "on-user-input" result
                       :key (lambda (e) (getf e :key)) :test #'string=)))
      (check (not (null entry)) "registered hook key surfaces in output")
      (check (= 2 (getf entry :handler-count))
             "handler count reflects two registered handlers"))))

;; ----------------------------------------------- harness-version ---

(defun test-builtin-version ()
  (format t "~%-- builtin-version --~%")
  (clear-all-tools)
  (install-builtin-tools!)
  (let ((result (dispatch-tool! 'harness-version nil)))
    (check (string= *version* result))))

;; ----------------------------------------------- harness-now ---

(defun test-builtin-now ()
  (format t "~%-- builtin-now --~%")
  (clear-all-tools)
  (install-builtin-tools!)
  (let ((result (dispatch-tool! 'harness-now nil)))
    (check (stringp result))
    (check (= 20 (length result))                        ; YYYY-MM-DDTHH:MM:SSZ
           (format nil "ISO-8601 length 20 (got ~D for ~S)" (length result) result))
    (check (char= #\Z (char result 19))
           "Z suffix on ISO-8601 UTC")))

;; --------------------------------------- LLM-facing schema conversion ---

(defun test-builtin-anthropic-descriptors ()
  "The LLM consumes tools via tool->anthropic-descriptor. Each builtin
should round-trip into a hash-table with the right shape."
  (format t "~%-- builtin-anthropic-descriptors --~%")
  (clear-all-tools)
  (install-builtin-tools!)
  (dolist (name *builtin-tool-names*)
    (let* ((tool (find-tool name))
           (desc (tool->anthropic-descriptor tool)))
      (check (string= (string-downcase (symbol-name name))
                      (cdr (assoc :name desc)))
             (format nil "~A descriptor :name field" name))
      (check (and (cdr (assoc :description desc))
                  (plusp (length (cdr (assoc :description desc)))))
             (format nil "~A descriptor :description non-empty" name)))))

;; --------------------------------------- end-to-end via turn-loop ---

(defun test-builtin-via-turn-loop ()
  "An agent equipped with the built-ins should be able to call one through
the full turn-loop — exercises that nothing in the introspection path
trips up the dispatch machinery."
  (format t "~%-- builtin-via-turn-loop --~%")
  (clear-all-hooks) (clear-all-tools)
  (install-builtin-tools!)
  (let* ((sup   (make-supervisor 'builtin-sup :max-restarts 3))
         (agent (make-instance 'agent
                               :id 'builtin-agent
                               :capability "harness:introspect"
                               :provider
                               (make-stub-provider
                                :responder
                                (lambda (m) (declare (ignore m))
                                  (list (list :tool-use "v1" 'harness-version nil))))
                               :tools *builtin-tool-names*)))
    (spawn-agent! sup agent)
    (sleep 0.05)
    (let* ((reply   (ask-agent agent "what version?"))
           (results (getf reply :tool-results)))
      (check (= 1 (length results)))
      (check (eq :ok (getf (first results) :status)))
      (check (string= *version* (getf (first results) :value))
             "harness-version dispatched through the turn loop"))
    (send! (agent-mailbox agent) :shutdown)
    (sleep 0.05)
    (drain-supervisor! sup)))

;; ----------------------------------------------- harness-describe-agent ---

(defun test-builtin-describe-agent-no-context ()
  (format t "~%-- builtin-describe-agent-no-context --~%")
  (clear-all-tools) (install-builtin-tools!)
  (let ((*current-agent* nil))
    (let ((result (dispatch-tool! 'harness-describe-agent nil)))
      (check (eq :no-current-agent (getf result :error))
             "outside a turn → :no-current-agent error"))))

(defun test-builtin-describe-agent ()
  (format t "~%-- builtin-describe-agent --~%")
  (clear-all-tools) (install-builtin-tools!)
  (let ((agent (make-instance 'agent
                              :id 'meta-agent
                              :capability "self:inspect"
                              :system-prompt "I introspect."
                              :tools '(harness-now harness-version))))
    (let ((*current-agent* agent))
      (let ((result (dispatch-tool! 'harness-describe-agent nil)))
        (check (search "META-AGENT" (getf result :id)))
        (check (string= "self:inspect" (getf result :capability)))
        (check (string= "I introspect." (getf result :system-prompt)))
        (check (= 2 (length (getf result :tools))))
        (check (member "harness-now" (getf result :tools) :test #'string=))))))

;; ----------------------------------------------- harness-query-receipts ---

(defun test-builtin-query-receipts-no-log ()
  (format t "~%-- builtin-query-receipts-no-log --~%")
  (clear-all-tools) (install-builtin-tools!)
  (let ((anuna-imago::*open-receipt-logs* nil))
    (let ((result (dispatch-tool! 'harness-query-receipts nil)))
      (check (eq :no-log (getf result :error))))))

(defun test-builtin-query-receipts ()
  (format t "~%-- builtin-query-receipts --~%")
  (clear-all-tools) (install-builtin-tools!)
  (let ((path (format nil "/tmp/imago-builtin-receipts-~A.log" (random 1000000))))
    (handler-case (delete-file path) (error () nil))
    (let ((log (open-receipt-log path))
          (saved-logs anuna-imago::*open-receipt-logs*))
      (unwind-protect
           (progn
             (setf anuna-imago::*open-receipt-logs* (list log))
             (loop for i from 0 below 7 do
               (append-receipt! log :receipt-id (format nil "r-~D" i)
                                    :direction :inbound
                                    :body (format nil "body-~D" i)))
             (let ((all (dispatch-tool! 'harness-query-receipts nil)))
               (check (= 7 (length all)) "default returns up to 10; 7 written"))
             (let ((subset (dispatch-tool! 'harness-query-receipts '(:limit 3))))
               (check (= 3 (length subset)) ":limit 3 returns 3 entries")
               ;; Should be the LAST 3 (r-4, r-5, r-6).
               (check (string= "r-4" (getf (first subset) :receipt-id)))
               (check (string= "r-6" (getf (third subset) :receipt-id)))))
        (close-receipt-log! log)
        (setf anuna-imago::*open-receipt-logs* saved-logs)
        (handler-case (delete-file path) (error () nil))))))

;; ----------------------------------------------- harness-uuid ---

(defun test-builtin-uuid ()
  (format t "~%-- builtin-uuid --~%")
  (clear-all-tools) (install-builtin-tools!)
  (let ((u1 (dispatch-tool! 'harness-uuid nil))
        (u2 (dispatch-tool! 'harness-uuid nil)))
    (check (= 36 (length u1)) "36 chars total (32 hex + 4 hyphens)")
    (check (= 36 (length u2)))
    (check (not (string= u1 u2)) "two UUIDs differ")
    (check (char= #\4 (char u1 14)) "version nibble (position 14) is 4")
    (check (member (char u1 19) '(#\8 #\9 #\a #\b))
           "variant nibble (position 19) is 8/9/a/b")
    (check (char= #\- (char u1 8)))
    (check (char= #\- (char u1 13)))
    (check (char= #\- (char u1 18)))
    (check (char= #\- (char u1 23)))))

;; ----------------------------------------------- harness-stats ---

(defun test-builtin-stats-no-agent ()
  (format t "~%-- builtin-stats-no-agent --~%")
  (clear-all-tools) (install-builtin-tools!)
  (let ((*current-agent* nil))
    (let ((result (dispatch-tool! 'harness-stats nil)))
      (check (numberp (getf result :uptime-seconds)))
      (check (string= *version* (getf result :version)))
      (check (= 10 (getf result :tool-count)))
      (check (null (getf result :mailbox-depth))
             "no agent → :mailbox-depth nil")
      (check (null (getf result :agent-state))))))

(defun test-builtin-stats-with-agent ()
  (format t "~%-- builtin-stats-with-agent --~%")
  (clear-all-tools) (install-builtin-tools!)
  (let ((agent (make-instance 'agent :id 'a :capability "x")))
    (send! (agent-mailbox agent) :a)
    (send! (agent-mailbox agent) :b)
    (let ((*current-agent* agent))
      (let ((result (dispatch-tool! 'harness-stats nil)))
        (check (= 2 (getf result :mailbox-depth))
               "mailbox depth reflects messages waiting")
        (check (eq :initialised (getf result :agent-state)))))))

;; ----------------------------------------------- harness-query-theory ---

(defun test-builtin-query-theory-no-theory ()
  (format t "~%-- builtin-query-theory-no-theory --~%")
  (clear-all-tools) (install-builtin-tools!)
  (let ((*active-theory-handle* nil))
    (let ((result (dispatch-tool! 'harness-query-theory '(:goal "(forbidden x)"))))
      (check (eq :no-theory (getf result :error))))))

(defun test-builtin-query-theory ()
  (format t "~%-- builtin-query-theory --~%")
  (clear-all-tools) (install-builtin-tools!)
  (let ((original *reasoner-ipc-call*))
    (unwind-protect
         (progn
           (setf *reasoner-ipc-call*
                 (lambda (op &rest args)
                   (declare (ignore args))
                   (case op
                     (:query (list :tag :+delta :time-ms 1 :derivation '(rule-1))))))
           (let ((*active-theory-handle* :handle-1))
             (let ((result (dispatch-tool! 'harness-query-theory
                                            '(:goal "(forbidden delete-user)"))))
               (check (eq :+delta (getf result :tag)))
               (check (numberp (getf result :time-ms)))
               (check (eq t (getf result :positive))
                      "+Δ → :positive t — but it does NOT veto"))))
      (setf *reasoner-ipc-call* original))))

(defun test-builtin-query-theory-missing-goal ()
  (format t "~%-- builtin-query-theory-missing-goal --~%")
  (clear-all-tools) (install-builtin-tools!)
  (let ((*active-theory-handle* :handle-1))
    (let ((result (dispatch-tool! 'harness-query-theory nil)))
      (check (eq :missing-goal (getf result :error))))))

;; ----------------------------------------------- runner ---

(defun run-builtin-tools-tests ()
  (setf *failures* 0)
  (format t "~%=== Built-in tools quality-gate tests ===~%")
  ;; Original 5 tools
  (test-builtin-list-tools)
  (test-builtin-describe-tool)
  (test-builtin-describe-tool-missing)
  (test-builtin-list-hooks)
  (test-builtin-version)
  (test-builtin-now)
  (test-builtin-anthropic-descriptors)
  (test-builtin-via-turn-loop)
  ;; Expanded tier
  (test-builtin-describe-agent-no-context)
  (test-builtin-describe-agent)
  (test-builtin-query-receipts-no-log)
  (test-builtin-query-receipts)
  (test-builtin-uuid)
  (test-builtin-stats-no-agent)
  (test-builtin-stats-with-agent)
  (test-builtin-query-theory-no-theory)
  (test-builtin-query-theory)
  (test-builtin-query-theory-missing-goal)
  (format t "~%=== ~D failure(s) ===~%" *failures*)
  (when (plusp *failures*) (sb-ext:exit :code 1))
  (format t "Built-in tools green.~%"))
