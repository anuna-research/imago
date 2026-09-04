;;;; openrouter-tests.lisp — OpenRouter provider driver tests
;;;;
;;;; Mirrors test/m8-tests.lisp's structure for the Anthropic driver.
;;;; All HTTP is stubbed via *openrouter-http-post*; no live API key needed.

(in-package #:anuna-imago.test)

(export 'run-openrouter-tests)

;; ------------------------------------------------- request shape ---

(defun test-openrouter-build-request-shape ()
  (format t "~%-- openrouter-build-request-shape --~%")
  (let* ((p (make-openrouter-provider :api-key "sk-or-test"
                                       :model "z-ai/glm-4.6"
                                       :max-tokens 256))
         (a (make-instance 'agent :id 'a
                                  :system-prompt "You are precise."
                                  :tools nil))
         (req (build-request p (make-ask "hello") a)))
    (check (string= "z-ai/glm-4.6" (gethash "model" req)))
    (check (= 256 (gethash "max_tokens" req)))
    (let ((msgs (gethash "messages" req)))
      ;; OpenRouter takes system-prompt as first messages[] element.
      (check (= 2 (length msgs)) "system + user messages")
      (check (string= "system" (gethash "role" (elt msgs 0))))
      (check (string= "You are precise." (gethash "content" (elt msgs 0))))
      (check (string= "user"   (gethash "role" (elt msgs 1))))
      (check (string= "hello"  (gethash "content" (elt msgs 1)))))))

(defun test-openrouter-build-request-no-system-prompt ()
  (format t "~%-- openrouter-build-request-no-system --~%")
  (let* ((p (make-openrouter-provider :api-key "k" :model "z-ai/glm-4.6"))
         (a (make-instance 'agent :id 'b :system-prompt nil :tools nil))
         (req (build-request p (make-ask "hi") a))
         (msgs (gethash "messages" req)))
    (check (= 1 (length msgs)) "user-only when no system prompt")
    (check (string= "user" (gethash "role" (elt msgs 0))))))

(defun test-openrouter-build-request-with-tools ()
  (format t "~%-- openrouter-build-request-with-tools --~%")
  (define-tool openrouter-test-greet
    :description "Greet someone."
    :permission :read
    :schema ((:name :type :string :required-p t :description "Person."))
    :handler (lambda (args) (format nil "Hi ~A" (getf args :name))))
  (let* ((p (make-openrouter-provider :api-key "k" :model "z-ai/glm-4.6"))
         (a (make-instance 'agent :id 'c
                                  :system-prompt nil
                                  :tools '(openrouter-test-greet)))
         (req (build-request p (make-ask "go") a))
         (tools (gethash "tools" req)))
    (check (= 1 (length tools)) "one tool serialised")
    (let* ((tool-ht (elt tools 0))
           (fn (gethash "function" tool-ht)))
      (check (string= "function" (gethash "type" tool-ht)))
      (check (string= "openrouter-test-greet" (gethash "name" fn)))
      (check (string= "Greet someone." (gethash "description" fn)))
      (let* ((params (gethash "parameters" fn))
             (props (gethash "properties" params)))
        (check (string= "object" (gethash "type" params)))
        (check (gethash "name" props))
        (check (find "name" (gethash "required" params) :test #'string=)))))
  (unregister-tool! 'openrouter-test-greet))

;; ------------------------------------------------- auth headers ---

(defun test-openrouter-auth-headers ()
  (format t "~%-- openrouter-auth-headers --~%")
  (let* ((p (make-openrouter-provider :api-key "sk-or-test-key"
                                       :model "z-ai/glm-4.6"
                                       :site-url "https://example.com"
                                       :app-name "imago-experiment"))
         (h (auth-headers p)))
    (check (string= "Bearer sk-or-test-key"
                    (cdr (assoc "Authorization" h :test #'string=))))
    (check (string= "application/json"
                    (cdr (assoc "Content-Type" h :test #'string=))))
    (check (string= "https://example.com"
                    (cdr (assoc "HTTP-Referer" h :test #'string=))))
    (check (string= "imago-experiment"
                    (cdr (assoc "X-Title" h :test #'string=))))))

(defun test-openrouter-auth-headers-from-env ()
  (format t "~%-- openrouter-auth-headers-from-env --~%")
  (let ((p (make-openrouter-provider :model "z-ai/glm-4.6"))
        (prior-key (sb-ext:posix-getenv "OPENROUTER_API_KEY")))
    (sb-posix:setenv "OPENROUTER_API_KEY" "env-key" 1)
    (unwind-protect
         (let ((h (auth-headers p)))
           (check (string= "Bearer env-key"
                           (cdr (assoc "Authorization" h :test #'string=)))))
      (if prior-key
          (sb-posix:setenv "OPENROUTER_API_KEY" prior-key 1)
          (sb-posix:unsetenv "OPENROUTER_API_KEY")))))

(defun test-openrouter-auth-missing-key ()
  (format t "~%-- openrouter-auth-missing-key --~%")
  (let ((prior-key (sb-ext:posix-getenv "OPENROUTER_API_KEY")))
    (unwind-protect
         (progn
           (sb-posix:unsetenv "OPENROUTER_API_KEY")
           (let ((p (make-openrouter-provider :model "z-ai/glm-4.6")))
             (check (handler-case (progn (auth-headers p) nil)
                      (error () t))
                    "auth-headers signals when no key + no env")))
      (when prior-key
        (sb-posix:setenv "OPENROUTER_API_KEY" prior-key 1)))))

;; ------------------------------------------------- response parsing ---

(defun %drain-openrouter-stream (stream-fn &key (limit 64))
  "Collect through :DONE, but fail instead of hanging on a broken stream."
  (let ((frames nil))
    (loop repeat limit
          for frame = (funcall stream-fn)
          do (push frame frames)
             (when (or (eq frame :done) (null frame))
               (return-from %drain-openrouter-stream (nreverse frames))))
    (error "OpenRouter stream exceeded ~D frames without terminating" limit)))

(defun %openrouter-semantic-integer= (expected wire-content)
  "Compare a tool-result content field after decoding its JSON scalar."
  (handler-case
      (let ((decoded (if (stringp wire-content)
                         (com.inuoe.jzon:parse wire-content)
                         wire-content)))
        (and (integerp decoded) (= expected decoded)))
    (error () nil)))

(defun %frame-of-kind (kind frames)
  (find kind frames :key (lambda (frame)
                           (and (consp frame) (first frame)))))

(defmacro with-openrouter-red-gate ((description) &body body)
  "Turn an unexpected provider signal into a normal test failure."
  `(handler-case
       (progn ,@body)
     (error (condition)
       (check nil (format nil "~A signalled unexpectedly: ~A"
                          ,description condition)))))

(defun test-openrouter-response-text-only ()
  (format t "~%-- openrouter-response-text-only --~%")
  (let* ((p (make-openrouter-provider :api-key "k" :model "z-ai/glm-4.6"))
         (a (make-instance 'agent :id 'd :system-prompt nil :tools nil))
         (canned (com.inuoe.jzon:stringify
                   (anuna-imago::%ht "id" "gen-1"
                        "choices"
                        (vector (anuna-imago::%ht "message"
                                     (anuna-imago::%ht "role" "assistant"
                                          "content" "hello back")
                                     "finish_reason" "stop")))))
         (*openrouter-http-post*
           (lambda (url &key headers content)
             (declare (ignore url headers content))
             canned))
         (stream-fn (provider-stream! p a (make-ask "hi"))))
    (let ((frames (%drain-openrouter-stream stream-fn)))
      (let ((text-frame (%frame-of-kind :text frames))
            (content-frame (%frame-of-kind :assistant-content frames))
            (stop-frame (%frame-of-kind :stop-reason frames)))
        (check (and text-frame (string= "hello back" (second text-frame))))
        (check content-frame "canonical assistant content is emitted")
        (check (and stop-frame (eq :end-turn (second stop-frame)))
               "OpenAI stop maps to canonical :end-turn")
        (check (eq :done (car (last frames))))
        (check (null (funcall stream-fn)) "stream drained")))))

(defun test-openrouter-response-tool-call ()
  (format t "~%-- openrouter-response-tool-call --~%")
  (let* ((p (make-openrouter-provider :api-key "k" :model "z-ai/glm-4.6"))
         (a (make-instance 'agent :id 'e :system-prompt nil :tools nil))
         (canned (com.inuoe.jzon:stringify
                   (anuna-imago::%ht "id" "gen-2"
                        "choices"
                        (vector (anuna-imago::%ht "message"
                                     (anuna-imago::%ht "role" "assistant"
                                          "content" nil
                                          "tool_calls"
                                          (vector (anuna-imago::%ht "id" "call_1"
                                                       "type" "function"
                                                       "function"
                                                       (anuna-imago::%ht "name" "harness-version"
                                                            "arguments" "{\"verbose\":true}"))))
                                     "finish_reason" "tool_calls")))))
         (*openrouter-http-post*
           (lambda (url &key headers content)
             (declare (ignore url headers content))
             canned))
         (stream-fn (provider-stream! p a (make-ask "version please"))))
    (let* ((frames (%drain-openrouter-stream stream-fn))
           (tool-frame (%frame-of-kind :tool-use frames))
           (content-frame (%frame-of-kind :assistant-content frames))
           (stop-frame (%frame-of-kind :stop-reason frames)))
      (check tool-frame)
      (check (string= "call_1" (second tool-frame)))
      (check (eq :harness-version (third tool-frame)))
      (check (eq t (getf (fourth tool-frame) :verbose))
             "JSON-string arguments parsed back to a plist")
      (check content-frame "tool-call assistant message is preserved")
      (check (and stop-frame (eq :tool-use (second stop-frame)))
             "tool_calls maps to canonical :tool-use")
      (check (eq :done (car (last frames)))))))

;; -------------------------------- SPEC-014 main-path integration ---

(defun test-openrouter-two-step-tool-drive-stream ()
  "TEST-002: exercise the real OpenRouter provider through DRIVE-STREAM."
  (format t "~%-- openrouter-two-step-tool-drive-stream (SPEC-014 TEST-002) --~%")
  (clear-all-hooks)
  (unregister-tool! 'anuna-imago::openrouter-loop-add)
  (let ((handler-calls 0)
        (requests nil)
        (responses
          (list
           (com.inuoe.jzon:stringify
            (anuna-imago::%ht
             "id" "gen-tool"
             "choices"
             (vector
              (anuna-imago::%ht
               "message"
               (anuna-imago::%ht
                "role" "assistant"
                "content" nil
                "tool_calls"
                (vector
                 (anuna-imago::%ht
                  "id" "call_add"
                  "type" "function"
                  "function"
                  (anuna-imago::%ht
                   "name" "openrouter-loop-add"
                   "arguments" "{\"a\":2,\"b\":3}"))))
               "finish_reason" "tool_calls"))))
           (com.inuoe.jzon:stringify
            (anuna-imago::%ht
             "id" "gen-final"
             "choices"
             (vector
              (anuna-imago::%ht
               "message"
               (anuna-imago::%ht "role" "assistant"
                                  "content" "sum is 5")
               "finish_reason" "stop")))))))
    (define-tool anuna-imago::openrouter-loop-add
      :description "Add two integers."
      :schema ((:a :type :integer :required-p t)
               (:b :type :integer :required-p t))
      :handler (lambda (args)
                 (incf handler-calls)
                 (+ (getf args :a) (getf args :b))))
    (with-openrouter-red-gate ("two-step OpenRouter loop")
      (unwind-protect
           (let* ((*openrouter-http-post*
                  (lambda (url &key headers content)
                    (declare (ignore url headers))
                    (push (com.inuoe.jzon:parse content) requests)
                    (or (pop responses)
                        (error "unexpected third OpenRouter request"))))
                (provider (make-openrouter-provider
                           :api-key "test-key" :model "test/model"))
                (agent (make-instance
                        'agent
                        :id 'openrouter-loop-agent
                        :capability "openrouter:tool-loop"
                        :provider provider
                        :tools '(anuna-imago::openrouter-loop-add)))
                (reply (drive-stream agent (make-ask "add two and three"))))
           (setf requests (nreverse requests))
           (check (= 2 (length requests)) "two provider requests complete the loop")
           (check (= 1 handler-calls) "tool handler runs exactly once")
           (check (string= "sum is 5" (getf reply :text)) "final assistant text returned")
           (let* ((results (getf reply :tool-results))
                  (result (first results)))
             (check (= 1 (length results)) "one tool result is retained")
             (check (eq :ok (getf result :status)))
             (check (= 5 (getf result :value))))
           (when (= 2 (length requests))
             (let* ((first-messages (gethash "messages" (first requests)))
                    (second-messages (gethash "messages" (second requests))))
               (check (= 1 (length first-messages)) "first request has one user message")
               (check (string= "add two and three"
                               (gethash "content" (elt first-messages 0)))
                      "canonical user content is not printed as a Lisp list")
               (check (= 3 (length second-messages))
                      "second request carries user, assistant, and tool history")
               (when (= 3 (length second-messages))
                 (let ((user-message (elt second-messages 0))
                       (assistant-message (elt second-messages 1))
                       (tool-message (elt second-messages 2)))
                   (check (string= "user" (gethash "role" user-message)))
                   (check (string= "assistant" (gethash "role" assistant-message)))
                   (check (= 1 (length (gethash "tool_calls" assistant-message)))
                          "assistant tool call survives round trip")
                   (check (string= "tool" (gethash "role" tool-message)))
                   (check (string= "call_add" (gethash "tool_call_id" tool-message)))
                   (check (%openrouter-semantic-integer=
                           5 (gethash "content" tool-message))
                          "tool result decodes to the computed integer")))))
           (let ((history (agent-message-history agent)))
             (check (>= (length history) 4)
                    "persisted history retains both assistant turns and tool feedback")
             (check (string= "add two and three" (getf (first history) :content)))))
        (unregister-tool! 'anuna-imago::openrouter-loop-add)))))

(defun test-openrouter-malformed-tool-arguments ()
  "TEST-023a: malformed JSON arguments yield an error result without dispatch."
  (format t "~%-- openrouter-malformed-tool-arguments (SPEC-014 TEST-023) --~%")
  (unregister-tool! 'anuna-imago::openrouter-malformed-target)
  (let ((handler-calls 0)
        (requests nil)
        (responses
          (list
           (com.inuoe.jzon:stringify
            (anuna-imago::%ht
             "choices"
             (vector
              (anuna-imago::%ht
               "message"
               (anuna-imago::%ht
                "role" "assistant" "content" nil
                "tool_calls"
                (vector
                 (anuna-imago::%ht
                  "id" "bad-call" "type" "function"
                  "function"
                  (anuna-imago::%ht
                   "name" "openrouter-malformed-target"
                   "arguments" "{not-json"))))
               "finish_reason" "tool_calls"))))
           (com.inuoe.jzon:stringify
            (anuna-imago::%ht
             "choices"
             (vector
              (anuna-imago::%ht
               "message" (anuna-imago::%ht
                            "role" "assistant" "content" "recovered")
               "finish_reason" "stop")))))))
    (define-tool anuna-imago::openrouter-malformed-target
      :schema ()
      :handler (lambda (args)
                 (declare (ignore args))
                 (incf handler-calls)
                 :must-not-run))
    (with-openrouter-red-gate ("malformed OpenRouter arguments")
      (unwind-protect
           (let* ((*openrouter-http-post*
                  (lambda (url &key headers content)
                    (declare (ignore url headers))
                    (push (com.inuoe.jzon:parse content) requests)
                    (or (pop responses) (error "unexpected request"))))
                (provider (make-openrouter-provider
                           :api-key "test-key" :model "test/model"))
                (seed-history
                  (list (list :role "user" :content "earlier")
                        (list :role "assistant" :content "earlier reply")))
                (agent (make-instance
                        'agent
                        :id 'openrouter-malformed-agent
                        :capability "openrouter:malformed"
                        :provider provider
                        :tools '(anuna-imago::openrouter-malformed-target))))
           (setf (agent-message-history agent) (copy-tree seed-history))
           (let* ((reply (drive-stream agent (make-ask "malformed request")))
                  (results (getf reply :tool-results))
                  (result (first results)))
             (setf requests (nreverse requests))
             (check (= 2 (length requests))
                    "error tool result is returned to the provider")
             (check (= 1 (length results)) "one malformed-argument result")
             (check (eq :error (getf result :status)))
             (check (zerop handler-calls) "malformed arguments never reach handler")
             (check (string= "recovered" (getf reply :text)))
             (when (= 2 (length requests))
               (let* ((messages (gethash "messages" (second requests)))
                      (assistant
                        (find-if
                         (lambda (message)
                           (let ((calls (gethash "tool_calls" message)))
                             (and (string= "assistant"
                                           (gethash "role" message))
                                  calls
                                  (plusp (length calls)))))
                         messages))
                      (tool-message
                        (find "tool" messages
                              :key (lambda (message) (gethash "role" message))
                              :test #'string=)))
                 (check assistant "second request retains the malformed assistant call")
                 (when assistant
                   (let* ((calls (gethash "tool_calls" assistant))
                          (call (and calls (plusp (length calls)) (elt calls 0)))
                          (function (and call (gethash "function" call))))
                     (check (and call (string= "bad-call" (gethash "id" call)))
                            "malformed call ID survives in assistant history")
                     (check (and function
                                 (string= "{not-json"
                                          (gethash "arguments" function)))
                            "original malformed arguments survive in assistant history")))
                 (check tool-message "second request contains an error tool result")
                 (when tool-message
                   (let ((content (gethash "content" tool-message)))
                     (check (string= "bad-call"
                                     (gethash "tool_call_id" tool-message))
                            "error result is correlated to the malformed call")
                     (check (and (stringp content)
                                 (search "error" content :test #'char-equal)
                                 (or (search "malformed" content :test #'char-equal)
                                     (search "invalid" content :test #'char-equal)))
                            "tool result semantically reports malformed arguments")))))
             (check (equal seed-history
                           (subseq (agent-message-history agent) 0 2))
                    "valid history prefix survives malformed arguments")))
        (unregister-tool! 'anuna-imago::openrouter-malformed-target)))))

(defun test-openrouter-unknown-finish-reason ()
  "TEST-023b: unknown finish reasons become canonical errors without history loss."
  (format t "~%-- openrouter-unknown-finish-reason (SPEC-014 TEST-023) --~%")
  (let* ((canned
           (com.inuoe.jzon:stringify
            (anuna-imago::%ht
             "choices"
             (vector
              (anuna-imago::%ht
               "message" (anuna-imago::%ht
                            "role" "assistant" "content" "valid partial text")
               "finish_reason" "future_reason")))))
         (*openrouter-http-post*
           (lambda (url &key headers content)
             (declare (ignore url headers content))
             canned))
         (provider (make-openrouter-provider :api-key "test-key"
                                              :model "test/model"))
         (seed-history (list (list :role "user" :content "earlier")))
         (agent (make-instance 'agent
                               :id 'openrouter-unknown-finish-agent
                               :capability "openrouter:malformed"
                               :provider provider
                               :tools nil)))
    (with-openrouter-red-gate ("unknown OpenRouter finish reason")
      (setf (agent-message-history agent) (copy-tree seed-history))
      (let* ((reply (drive-stream agent (make-ask "new request")))
             (results (getf reply :tool-results)))
        (check (= 1 (length results)) "unknown finish produces one error result")
        (check (getf (first results) :error) "unknown finish is reported as an error")
        (check (string= "valid partial text" (getf reply :text))
               "valid assistant text is preserved")
        (check (equal seed-history
                      (subseq (agent-message-history agent) 0 1))
               "valid history prefix survives unknown finish reason")))))

(defun test-openrouter-response-error-envelope ()
  (format t "~%-- openrouter-response-error-envelope --~%")
  (let* ((p (make-openrouter-provider :api-key "k" :model "z-ai/glm-4.6"))
         (a (make-instance 'agent :id 'f :system-prompt nil :tools nil))
         (canned (com.inuoe.jzon:stringify
                   (anuna-imago::%ht "error" (anuna-imago::%ht "code" 401
                                     "message" "auth failed"))))
         (*openrouter-http-post*
           (lambda (url &key headers content)
             (declare (ignore url headers content))
             canned))
         (stream-fn (provider-stream! p a (make-ask "x"))))
    (let ((f1 (funcall stream-fn)))
      (check (and (consp f1) (eq :error (first f1))))
      (check (string= "openrouter" (getf (second f1) :provider)))
      (check (eq :api-error (getf (second f1) :status))))))

(defun test-openrouter-http-error-becomes-frame ()
  (format t "~%-- openrouter-http-error-becomes-frame --~%")
  (let* ((p (make-openrouter-provider :api-key "k" :model "z-ai/glm-4.6"))
         (a (make-instance 'agent :id 'g :system-prompt nil :tools nil))
         (*openrouter-http-post*
           (lambda (url &key headers content)
             (declare (ignore url headers content))
             (error "simulated transport failure")))
         (stream-fn (provider-stream! p a (make-ask "x"))))
    (let ((f1 (funcall stream-fn))
          (f2 (funcall stream-fn)))
      (check (and (consp f1) (eq :error (first f1))))
      (check (eq :request-failed (getf (second f1) :status)))
      (check (eq :done f2)))))

;; ------------------------------------------------- credential cleanup ---

(defun test-openrouter-credential-eraser ()
  (format t "~%-- openrouter-credential-eraser --~%")
  (let ((p (make-openrouter-provider :api-key "to-be-cleared"
                                      :model "z-ai/glm-4.6")))
    (check (string= "to-be-cleared" (openrouter-api-key p)))
    ;; The provider registered a thunk; running the checklist clears it.
    (let ((anuna-imago::*credential-erasers*
            (copy-list anuna-imago::*credential-erasers*)))
      (pre-save-clean!)
      (check (null (openrouter-api-key p)) "api-key zeroed after :clean"))))

;; ------------------------------------------------- runner ---

(defun run-openrouter-tests ()
  (format t "~%========================================~%")
  (format t " OpenRouter provider driver~%")
  (format t "========================================~%")
  (let ((*failures* 0))
    (test-openrouter-build-request-shape)
    (test-openrouter-build-request-no-system-prompt)
    (test-openrouter-build-request-with-tools)
    (test-openrouter-auth-headers)
    (test-openrouter-auth-headers-from-env)
    (test-openrouter-auth-missing-key)
    (test-openrouter-response-text-only)
    (test-openrouter-response-tool-call)
    (test-openrouter-two-step-tool-drive-stream)
    (test-openrouter-malformed-tool-arguments)
    (test-openrouter-unknown-finish-reason)
    (test-openrouter-response-error-envelope)
    (test-openrouter-http-error-becomes-frame)
    (test-openrouter-credential-eraser)
    (cond ((zerop *failures*)
           (format t "~%~%PASS — openrouter provider tests~%")
           t)
          (t
           (format t "~%~%FAIL — ~D failures in openrouter tests~%" *failures*)
           (error "OpenRouter test suite failed with ~D failure~:P"
                  *failures*)))))
