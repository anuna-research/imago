;;;; m8-tests.lisp — quality-gate tests for M8 (Anthropic provider)
;;;;
;;;; These tests do NOT call the live API. *ANTHROPIC-HTTP-POST* is rebound
;;;; to a stub returning canned JSON. A live-API smoke is gated on having
;;;; ANTHROPIC_API_KEY set and is left as a manual REPL exercise.

(in-package #:anuna-imago.test)

(export 'run-m8-tests)

(defun %canned-text-response (text)
  "Build a JSON string mimicking a non-streaming Messages API response
that contains a single text content block."
  (com.inuoe.jzon:stringify
   (let ((h (make-hash-table :test 'equal)))
     (setf (gethash "id" h) "msg_test")
     (setf (gethash "type" h) "message")
     (setf (gethash "role" h) "assistant")
     (setf (gethash "model" h) "claude-test")
     (setf (gethash "stop_reason" h) "end_turn")
     (setf (gethash "content" h)
           (vector
            (let ((b (make-hash-table :test 'equal)))
              (setf (gethash "type" b) "text")
              (setf (gethash "text" b) text)
              b)))
     h)))

(defun %canned-tool-use-response (tool-id tool-name input-ht)
  "Canned response with a single tool_use content block."
  (com.inuoe.jzon:stringify
   (let ((h (make-hash-table :test 'equal)))
     (setf (gethash "id" h) "msg_test_tool")
     (setf (gethash "stop_reason" h) "tool_use")
     (setf (gethash "content" h)
           (vector
            (let ((b (make-hash-table :test 'equal)))
              (setf (gethash "type" b) "tool_use")
              (setf (gethash "id" b) tool-id)
              (setf (gethash "name" b) tool-name)
              (setf (gethash "input" b) input-ht)
              b)))
     h)))

;; ------------------------------------------ build-request ---

(defun test-build-request-shape ()
  (format t "~%-- anthropic-build-request-shape --~%")
  (let* ((p (make-anthropic-provider :api-key "test" :model "claude-test"
                                     :max-tokens 100))
         (a (make-instance 'agent :id 'a :capability "x:y"
                                  :system-prompt "You are X."))
         (req (build-request p (make-ask "hello") a)))
    (check (string= "claude-test" (gethash "model" req)))
    (check (= 100 (gethash "max_tokens" req)))
    (check (string= "You are X." (gethash "system" req)))
    (let ((msgs (gethash "messages" req)))
      (check (= 1 (length msgs)))
      (let ((m (aref msgs 0)))
        (check (string= "user" (gethash "role" m)))
        (check (string= "hello" (gethash "content" m)))))))

(defun test-build-request-with-tools ()
  (format t "~%-- anthropic-build-request-with-tools --~%")
  (clear-all-tools)
  (define-tool greet
    :description "Greet someone."
    :schema ((:name :type :string :required-p t :description "Person"))
    :handler (lambda (a) (declare (ignore a)) "ok"))
  (let* ((p (make-anthropic-provider :api-key "test"))
         (a (make-instance 'agent :id 'a :capability "x")))
    (setf (agent-tools a) '(greet))
    (let* ((req (build-request p (make-ask "hi") a))
           (tools (gethash "tools" req)))
      (check (and tools (= 1 (length tools))))
      (let ((tool (aref tools 0)))
        (check (string= "greet" (gethash "name" tool)))
        (check (string= "Greet someone." (gethash "description" tool)))
        (let* ((schema (gethash "input_schema" tool))
               (props  (gethash "properties" schema)))
          (check (string= "object" (gethash "type" schema)))
          (check (= 1 (hash-table-count props)))
          (let ((nameprop (gethash "name" props)))
            (check (string= "string" (gethash "type" nameprop)))))))))

;; ------------------------------------------ auth-headers ---

(defun test-auth-headers-from-slot ()
  (format t "~%-- anthropic-auth-headers-from-slot --~%")
  (let* ((p (make-anthropic-provider :api-key "sk-test-1234"))
         (h (auth-headers p)))
    (check (string= "sk-test-1234" (cdr (assoc "x-api-key" h :test #'string=))))
    (check (string= "2023-06-01"
                    (cdr (assoc "anthropic-version" h :test #'string=))))
    (check (string= "application/json"
                    (cdr (assoc "content-type" h :test #'string=))))))

(defun test-auth-headers-missing ()
  (format t "~%-- anthropic-auth-headers-missing --~%")
  (let ((p (make-anthropic-provider))
        (existing (uiop:getenv "ANTHROPIC_API_KEY")))
    ;; Temporarily clear env (best-effort — UIOP doesn't have unsetenv on all impls)
    (unwind-protect
         (cond
           (existing
            (format t "  (skipped: ANTHROPIC_API_KEY is set in environment)~%")
            (check t))
           (t
            (check (handler-case
                       (progn (auth-headers p) nil)
                     (error () t))
                   "missing api-key + missing env errors")))
      nil)))

;; ------------------------------------------ stream! end-to-end ---

(defun test-stream-text-frames ()
  (format t "~%-- anthropic-stream-text-frames --~%")
  (let* ((p (make-anthropic-provider :api-key "test"))
         (a (make-instance 'agent :id 'a :capability "x"))
         (canned (%canned-text-response "Hello, world.")))
    (let ((*anthropic-http-post*
            (lambda (url &key headers content)
              (declare (ignore url headers content))
              canned)))
      (let ((stream (provider-stream! p a (make-ask "hi"))))
        (let ((frames nil))
          (loop for f = (stream-next-frame! stream)
                until (eq f :done)
                do (push f frames))
          (setf frames (nreverse frames))
          (check (= 1 (length frames)))
          (let ((f (first frames)))
            (check (eq :text (first f)))
            (check (string= "Hello, world." (second f)))))))))

(defun test-stream-tool-use-frame ()
  (format t "~%-- anthropic-stream-tool-use-frame --~%")
  (let* ((p (make-anthropic-provider :api-key "test"))
         (a (make-instance 'agent :id 'a :capability "x"))
         (input (let ((h (make-hash-table :test 'equal)))
                  (setf (gethash "name" h) "World")
                  h))
         (canned (%canned-tool-use-response "toolu_1" "greet" input)))
    (let ((*anthropic-http-post*
            (lambda (url &key headers content)
              (declare (ignore url headers content))
              canned)))
      (let ((stream (provider-stream! p a (make-ask "say hi"))))
        (let ((frames nil))
          (loop for f = (stream-next-frame! stream)
                until (eq f :done)
                do (push f frames))
          (setf frames (nreverse frames))
          (check (= 1 (length frames)))
          (let ((f (first frames)))
            (check (eq :tool-use (first f)))
            (check (string= "toolu_1" (second f)))
            (check (eq :greet (third f)))
            (check (string= "World" (getf (fourth f) :name)))))))))

(defun test-stream-http-error-becomes-frame ()
  "An HTTP layer error should surface as an :error frame followed by :done,
not as an unhandled condition that crashes the agent."
  (format t "~%-- anthropic-http-error-becomes-frame --~%")
  (let* ((p (make-anthropic-provider :api-key "test"))
         (a (make-instance 'agent :id 'a :capability "x")))
    (let ((*anthropic-http-post*
            (lambda (url &key headers content)
              (declare (ignore url headers content))
              (error "simulated network failure"))))
      (let ((stream (provider-stream! p a (make-ask "hi"))))
        (let ((first-frame  (stream-next-frame! stream))
              (second-frame (stream-next-frame! stream)))
          (check (eq :error (first first-frame)))
          (check (eq :done second-frame)))))))

;; ------------------------------------------ end-to-end through turn-loop ---

(defun test-anthropic-via-turn-loop ()
  "End-to-end through the supervised turn-loop. Note: we mutate
*ANTHROPIC-HTTP-POST* globally rather than LET-rebind it because the
agent runs in a child thread (sb-thread bindings are per-thread)."
  (format t "~%-- anthropic-via-turn-loop --~%")
  (clear-all-hooks) (clear-all-tools)
  (let* ((p        (make-anthropic-provider :api-key "test"))
         (sup      (make-supervisor 'anth-sup :max-restarts 3))
         (agent    (make-instance 'agent :id 'anth-agent :capability "x:y"
                                          :provider p
                                          :system-prompt "You are testy."))
         (canned   (%canned-text-response "hello back"))
         (original *anthropic-http-post*))
    (unwind-protect
         (progn
           (setf *anthropic-http-post*
                 (lambda (url &key headers content)
                   (declare (ignore url headers content))
                   canned))
           (spawn-agent! sup agent)
           (sleep 0.05)
           (let ((reply (ask-agent agent "hi")))
             (check (string= "hello back" (getf reply :text))
                    "anthropic provider drives full turn-loop end-to-end")))
      (setf *anthropic-http-post* original)
      (handler-case (send! (agent-mailbox agent) :shutdown) (error () nil))
      (sleep 0.05)
      (drain-supervisor! sup))))

;; ------------------------------------------ credential cleanup wiring ---

(defun test-credential-eraser-wired ()
  (format t "~%-- anthropic-credential-eraser-wired --~%")
  (let ((p (make-anthropic-provider :api-key "secret")))
    (check (string= "secret" (anthropic-api-key p)))
    (pre-save-clean!)
    (check (null (anthropic-api-key p))
           "pre-save-clean! erases anthropic api-key")))

;; ---------------------------------------------------------------- runner ---

(defun run-m8-tests ()
  (setf *failures* 0)
  (format t "~%=== M8 quality-gate tests ===~%")
  (test-build-request-shape)
  (test-build-request-with-tools)
  (test-auth-headers-from-slot)
  (test-auth-headers-missing)
  (test-stream-text-frames)
  (test-stream-tool-use-frame)
  (test-stream-http-error-becomes-frame)
  (test-anthropic-via-turn-loop)
  (test-credential-eraser-wired)
  (format t "~%=== ~D failure(s) ===~%" *failures*)
  (when (plusp *failures*) (sb-ext:exit :code 1))
  (format t "M8 green.~%"))
