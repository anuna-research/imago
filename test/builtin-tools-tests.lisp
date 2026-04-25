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

;; ----------------------------------------------- runner ---

(defun run-builtin-tools-tests ()
  (setf *failures* 0)
  (format t "~%=== Built-in tools quality-gate tests ===~%")
  (test-builtin-list-tools)
  (test-builtin-describe-tool)
  (test-builtin-describe-tool-missing)
  (test-builtin-list-hooks)
  (test-builtin-version)
  (test-builtin-now)
  (test-builtin-anthropic-descriptors)
  (test-builtin-via-turn-loop)
  (format t "~%=== ~D failure(s) ===~%" *failures*)
  (when (plusp *failures*) (sb-ext:exit :code 1))
  (format t "Built-in tools green.~%"))
