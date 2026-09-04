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

(defun %openrouter-package-registry-snapshot ()
  (list
   (sort (mapcar #'package-name (list-all-packages)) #'string<)
   (sort (loop for symbol being the symbols of (find-package :keyword)
               collect (symbol-name symbol)) #'string<)
   (sort (loop for symbol being the symbols of (find-package :anuna-imago)
               collect (symbol-name symbol)) #'string<)))

(defun %openrouter-test-call (id &key
                                   (name "openrouter-boundary-target")
                                   (arguments "{}")
                                   (type "function"))
  (anuna-imago::%ht
   "id" id "type" type
   "function" (anuna-imago::%ht "name" name "arguments" arguments)))

(defun %openrouter-test-tool-body (calls)
  (com.inuoe.jzon:stringify
   (anuna-imago::%ht
    "choices"
    (vector
     (anuna-imago::%ht
      "message" (anuna-imago::%ht
                 "role" "assistant" "content" 'null
                 "tool_calls" (coerce calls 'vector))
      "finish_reason" "tool_calls")))))

(defun %openrouter-test-stop-body ()
  (com.inuoe.jzon:stringify
   (anuna-imago::%ht
    "choices" (vector (anuna-imago::%ht
                       "message" (anuna-imago::%ht
                                  "role" "assistant" "content" "done")
                       "finish_reason" "stop")))))

(defun %openrouter-nested-array-json (depth)
  "Return one scalar wrapped in exactly DEPTH JSON arrays."
  (concatenate 'string
               (make-string depth :initial-element #\[)
               "0"
               (make-string depth :initial-element #\])))

(defun %openrouter-flat-array-json (element-count)
  "Return a JSON array containing ELEMENT-COUNT zero values."
  (with-output-to-string (stream)
    (write-char #\[ stream)
    (dotimes (index element-count)
      (when (plusp index) (write-char #\, stream))
      (write-char #\0 stream))
    (write-char #\] stream)))

(defun %openrouter-flat-object-json (key-count)
  "Return a JSON object containing KEY-COUNT distinct scalar fields."
  (with-output-to-string (stream)
    (write-char #\{ stream)
    (dotimes (index key-count)
      (when (plusp index) (write-char #\, stream))
      (format stream "\"k~D\":0" index))
    (write-char #\} stream)))

(defun %openrouter-node-boundary-json (last-array-size)
  "Return a depth-two JSON value near the 8,192-node ceiling.

Thirty-one child arrays contain 255 scalars.  The final child contains
LAST-ARRAY-SIZE scalars, so 254 produces exactly 8,192 counted nodes and 255
produces 8,193 without crossing another resource ceiling."
  (with-output-to-string (stream)
    (write-char #\[ stream)
    (dotimes (index 31)
      (when (plusp index) (write-char #\, stream))
      (write-string (%openrouter-flat-array-json 255) stream))
    (write-char #\, stream)
    (write-string (%openrouter-flat-array-json last-array-size) stream)
    (write-char #\] stream)))

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
                                          "content" 'null
                                          "tool_calls"
                                          (vector (anuna-imago::%ht "id" "call_1"
                                                       "type" "function"
                                                       "function"
                                                       (anuna-imago::%ht
                                                        "name" "harness-describe-tool"
                                                        "arguments"
                                                        "{\"name\":\"harness-version\"}"))))
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
      (check (anuna-imago::%tool-name-equal-p
              'harness-describe-tool (third tool-frame)))
      (check (string= "harness-version" (getf (fourth tool-frame) :name))
             "JSON arguments are recognized against the registered schema")
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
                "content" 'null
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
                "role" "assistant" "content" 'null
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

(defun test-openrouter-closed-response-grammar ()
  "TEST-064: provider bytes are fully recognized before any tool action."
  (format t "~%-- openrouter-closed-response-grammar (SPEC-014 TEST-064) --~%")
  (unregister-tool! 'anuna-imago::openrouter-boundary-target)
  (let* ((handler-calls 0)
         (provider (make-openrouter-provider :api-key "test-key"
                                              :model "test/model"))
         (normal (%openrouter-test-stop-body))
         (unknown-name "imago-provider-must-not-intern-9f14a7")
         (tools-before (sort (mapcar #'symbol-name (list-tools)) #'string<))
         (packages-before (%openrouter-package-registry-snapshot))
         (all-safe-p t))
    (define-tool anuna-imago::openrouter-boundary-target
      :schema ((:value :type :integer :required-p nil)
               (:items :type :array :required-p nil)
               (:text :type :string :required-p nil)
               (:ratio :type :number :required-p nil)
               (:flag :type :boolean :required-p nil)
               (:record :type :object :required-p nil))
      :handler (lambda (args)
                 (declare (ignore args))
                 (incf handler-calls)
                 :must-not-run))
    (labels ((run-agent (body &optional status)
               (let ((first-response-p t))
                 (let ((*openrouter-http-post*
                         (lambda (url &key headers content)
                           (declare (ignore url headers content))
                           (if first-response-p
                               (progn (setf first-response-p nil)
                                      (values body status))
                               (values normal 200)))))
                   (drive-stream
                    (make-instance 'agent
                                   :id 'openrouter-boundary-agent
                                   :capability "openrouter:boundary"
                                   :provider provider
                                   :tools '(anuna-imago::openrouter-boundary-target))
                    (make-ask "do not execute malformed provider data")))))
             (fetch (body &optional (status 200))
               (let ((*openrouter-http-post*
                       (lambda (url &key headers content)
                         (declare (ignore url headers content))
                         (values body status))))
                 (anuna-imago::%openrouter-fetch-and-parse
                  provider (anuna-imago::%ht))))
             (fetch-stream (octets &optional (status 200))
               (let* ((constructor
                        (find-symbol "MAKE-IN-MEMORY-INPUT-STREAM"
                                     :flexi-streams))
                      (stream (funcall constructor octets)))
                 (values
                  (let ((*openrouter-http-post*
                          (lambda (url &key headers content)
                            (declare (ignore url headers content))
                            (values stream status))))
                    (anuna-imago::%openrouter-fetch-and-parse
                     provider (anuna-imago::%ht)))
                  stream))))
      (let* ((missing-id (%openrouter-test-call "missing"))
             (numeric-id (%openrouter-test-call 7))
             (wrong-type (%openrouter-test-call "wrong-type" :type "command"))
             (numeric-name (%openrouter-test-call "numeric-name"))
             (numeric-args (%openrouter-test-call "numeric-args"))
             (extra-call (%openrouter-test-call "extra-call"))
             (extra-function (%openrouter-test-call "extra-function"))
             (unknown-tool (%openrouter-test-call "unknown" :name unknown-name))
             (unknown-argument
               (%openrouter-test-call "unknown-argument"
                                      :arguments "{\"surprise\":1}"))
             (wrong-argument-type
               (%openrouter-test-call "wrong-argument-type"
                                      :arguments "{\"value\":\"no\"}"))
             (wrong-string-type
               (%openrouter-test-call "wrong-string-type"
                                      :arguments "{\"text\":false}"))
             (wrong-number-type
               (%openrouter-test-call "wrong-number-type"
                                      :arguments "{\"ratio\":\"no\"}"))
             (wrong-boolean-type
               (%openrouter-test-call "wrong-boolean-type"
                                      :arguments "{\"flag\":null}"))
             (wrong-object-type
               (%openrouter-test-call "wrong-object-type"
                                      :arguments "{\"record\":[]}"))
             (false-array
               (%openrouter-test-call "false-array"
                                      :arguments "{\"items\":false}")))
        (remhash "id" missing-id)
        (setf (gethash "name" (gethash "function" numeric-name)) 42
              (gethash "arguments" (gethash "function" numeric-args)) 42
              (gethash "extra" extra-call) t
              (gethash "extra" (gethash "function" extra-function)) t)
        (let* ((valid-call (%openrouter-test-call "ambiguous"))
               (ambiguous
                 (com.inuoe.jzon:parse
                  (%openrouter-test-tool-body (list valid-call))
                  :key-fn nil)))
          (setf (gethash "error" ambiguous)
                (anuna-imago::%ht "message" "must dominate choices"))
          (dolist (body
                    (list
                     (%openrouter-test-tool-body (list missing-id))
                     (%openrouter-test-tool-body (list numeric-id))
                     (%openrouter-test-tool-body (list wrong-type))
                     (%openrouter-test-tool-body (list numeric-name))
                     (%openrouter-test-tool-body (list numeric-args))
                     (%openrouter-test-tool-body (list extra-call))
                     (%openrouter-test-tool-body (list extra-function))
                     (%openrouter-test-tool-body (list unknown-tool))
                     (%openrouter-test-tool-body (list unknown-argument))
                     (%openrouter-test-tool-body (list wrong-argument-type))
                     (%openrouter-test-tool-body (list wrong-string-type))
                     (%openrouter-test-tool-body (list wrong-number-type))
                     (%openrouter-test-tool-body (list wrong-boolean-type))
                     (%openrouter-test-tool-body (list wrong-object-type))
                     (%openrouter-test-tool-body (list false-array))
                     (%openrouter-test-tool-body
                      (list (%openrouter-test-call "duplicate")
                            (%openrouter-test-call "duplicate")))
                     (com.inuoe.jzon:stringify ambiguous)
                     "{\"choices\":[],\"choices\":[]}"
                     "{\"choices\":[],\"unknown\":true}"
                     "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":false},\"finish_reason\":\"stop\"}]}"
                     "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null,\"refusal\":false},\"finish_reason\":\"stop\"}]}"
                     "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"ok\"},\"finish_reason\":\"stop\"}],\"usage\":false}"
                     "{\"error\":{\"message\":\"x\"},\"id\":{}}"
                     "{\"error\":{\"message\":\"x\"},\"request_id\":false}"
                     "{\"error\":{\"message\":\"x\",\"code\":false}}"
                     "{\"error\":{\"message\":\"x\",\"metadata\":[]}}"))
            (run-agent body)))
        ;; Required/type/duplicate/closed-shape failures at every nested
        ;; action-bearing layer.  Raw strings preserve duplicate keys, which
        ;; a materialized hash table cannot represent.
        (dolist
            (body
             (list
              "{}"
              "{\"error\":{}}"
              "{\"error\":{\"message\":7}}"
              "{\"error\":{\"message\":\"x\",\"message\":\"y\"}}"
              "{\"error\":{\"message\":\"x\",\"unknown\":0}}"
              "{\"choices\":false}"
              "{\"choices\":[],\"id\":7}"
              "{\"choices\":[],\"object\":7}"
              "{\"choices\":[],\"model\":7}"
              "{\"choices\":[],\"system_fingerprint\":7}"
              "{\"choices\":[],\"provider\":7}"
              "{\"choices\":[],\"created\":false}"
              "{\"choices\":[],\"created\":-1}"
              "{\"choices\":[],\"usage\":{\"prompt_tokens\":false}}"
              "{\"choices\":[],\"usage\":{\"completion_tokens\":-1}}"
              "{\"choices\":[],\"usage\":{\"total_tokens\":false}}"
              "{\"choices\":[],\"usage\":{\"cost\":false}}"
              "{\"choices\":[],\"usage\":{\"cost\":-1}}"
              "{\"choices\":[],\"usage\":{\"is_byok\":null}}"
              "{\"choices\":[],\"usage\":{\"prompt_tokens_details\":[]}}"
              "{\"choices\":[],\"usage\":{\"completion_tokens_details\":[]}}"
              "{\"choices\":[],\"usage\":{\"prompt_tokens_details\":{\"unknown\":0}}}"
              "{\"choices\":[],\"usage\":{\"prompt_tokens_details\":{\"cached_tokens\":false}}}"
              "{\"choices\":[],\"usage\":{\"completion_tokens_details\":{\"reasoning_tokens\":-1}}}"
              "{\"choices\":[],\"usage\":{\"unknown\":0}}"
              "{\"choices\":[],\"usage\":{\"cost\":0,\"cost\":1}}"
              "{\"choices\":[],\"usage\":{\"prompt_tokens_details\":{\"cached_tokens\":0,\"cached_tokens\":1}}}"
              "{\"choices\":[false]}"
              "{\"choices\":[{\"finish_reason\":\"stop\"}]}"
              "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"x\"}}]}"
              "{\"choices\":[{\"message\":false,\"finish_reason\":\"stop\"}]}"
              "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"x\"},\"finish_reason\":false}]}"
              "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"x\"},\"finish_reason\":\"stop\",\"index\":false}]}"
              "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"x\"},\"finish_reason\":\"stop\",\"index\":-1}]}"
              "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"x\"},\"finish_reason\":\"stop\",\"native_finish_reason\":false}]}"
              "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"x\"},\"finish_reason\":\"stop\",\"logprobs\":{}}]}"
              "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"x\"},\"message\":{\"role\":\"assistant\",\"content\":\"y\"},\"finish_reason\":\"stop\"}]}"
              "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"x\"},\"finish_reason\":\"stop\",\"unknown\":0}]}"
              "{\"choices\":[{\"message\":{\"content\":\"x\"},\"finish_reason\":\"stop\"}]}"
              "{\"choices\":[{\"message\":{\"role\":\"assistant\"},\"finish_reason\":\"stop\"}]}"
              "{\"choices\":[{\"message\":{\"role\":\"user\",\"content\":\"x\"},\"finish_reason\":\"stop\"}]}"
              "{\"choices\":[{\"message\":{\"role\":false,\"content\":\"x\"},\"finish_reason\":\"stop\"}]}"
              "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"x\",\"role\":\"assistant\"},\"finish_reason\":\"stop\"}]}"
              "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"x\",\"unknown\":0},\"finish_reason\":\"stop\"}]}"
              "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"x\",\"reasoning\":false},\"finish_reason\":\"stop\"}]}"
              "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":false},\"finish_reason\":\"tool_calls\"}]}"
              "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[]},\"finish_reason\":\"tool_calls\"}]}"
              "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"x\",\"tool_calls\":[{\"id\":\"x\",\"type\":\"function\",\"function\":{\"name\":\"openrouter-boundary-target\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"stop\"}]}"
              "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"type\":\"function\",\"function\":{\"name\":\"openrouter-boundary-target\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}"
              "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"x\",\"function\":{\"name\":\"openrouter-boundary-target\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}"
              "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"x\",\"type\":\"function\"}]},\"finish_reason\":\"tool_calls\"}]}"
              "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"x\",\"type\":\"function\",\"function\":false}]},\"finish_reason\":\"tool_calls\"}]}"
              "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"x\",\"id\":\"y\",\"type\":\"function\",\"function\":{\"name\":\"openrouter-boundary-target\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}"
              "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"x\",\"type\":\"function\",\"function\":{\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}"
              "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"x\",\"type\":\"function\",\"function\":{\"name\":\"openrouter-boundary-target\"}}]},\"finish_reason\":\"tool_calls\"}]}"
              "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"x\",\"type\":\"function\",\"function\":{\"name\":\"openrouter-boundary-target\",\"name\":\"openrouter-boundary-target\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}"
              "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"x\",\"type\":\"function\",\"function\":{\"name\":\"openrouter-boundary-target\",\"arguments\":\"{\\\"value\\\":1,\\\"value\\\":2}\"}}]},\"finish_reason\":\"tool_calls\"}]}"))
          (run-agent body))
        (let ((valid-array-frames
                (fetch
                 (%openrouter-test-tool-body
                  (list (%openrouter-test-call
                         "valid-array" :arguments "{\"items\":[]}"))))))
          (check (= 1 (count :tool-use valid-array-frames
                             :key (lambda (frame)
                                    (and (consp frame) (first frame)))))
                 "an actual JSON array remains admissible without dispatch"))
        (let* ((frames
                 (fetch
                  (%openrouter-test-tool-body
                   (list
                    (%openrouter-test-call
                     "valid-schema-types"
                     :arguments
                     "{\"value\":1,\"items\":[],\"text\":\"x\",\"ratio\":1.5,\"flag\":false,\"record\":{}}")))))
               (tool-frame (%frame-of-kind :tool-use frames))
               (args (and tool-frame (fourth tool-frame))))
          (check tool-frame "all declared JSON schema types are recognized")
          (when tool-frame
            (check (and (= 1 (getf args :value))
                        (vectorp (getf args :items))
                        (string= "x" (getf args :text))
                        (realp (getf args :ratio))
                        (null (getf args :flag))
                        (hash-table-p (getf args :record)))
                   "recognized arguments retain unambiguous Jzon types")))
        ;; A non-2xx status cannot be overridden by a syntactically valid body.
        (run-agent (%openrouter-test-tool-body
                    (list (%openrouter-test-call "non-2xx")))
                   500)
        ;; Tool-call count has an exact 16/17 boundary.
        (let* ((sixteen
                 (loop for index below 16
                       collect (%openrouter-test-call
                                (format nil "bounded-~D" index))))
               (sixteen-frames (fetch (%openrouter-test-tool-body sixteen)))
               (seventeen-frames
                 (fetch (%openrouter-test-tool-body
                         (append sixteen
                                 (list (%openrouter-test-call "bounded-16")))))))
          (check (= 16 (count :tool-use sixteen-frames
                              :key (lambda (frame)
                                     (and (consp frame) (first frame)))))
                 "sixteen fully recognized calls are admitted")
          (check (null (%frame-of-kind :tool-use seventeen-frames))
                 "the seventeenth call rejects the complete response"))
        ;; Every generic JSON recognition ceiling has an exact positive and
        ;; one-over negative case.  These values isolate the selected ceiling
        ;; so a lower bound cannot accidentally make the assertion pass.
        (flet ((parse-accepted-p (text)
                 (handler-case
                     (progn
                       (anuna-imago::%openrouter-parse-json
                        text (* 1024 1024) "OpenRouter boundary test")
                       t)
                   (error () nil))))
          (check (parse-accepted-p (%openrouter-nested-array-json 32))
                 "exactly 32 JSON container levels are accepted")
          (check (not (parse-accepted-p (%openrouter-nested-array-json 33)))
                 "the 33rd JSON container level is rejected")
          (check (parse-accepted-p (%openrouter-node-boundary-json 254))
                 "exactly 8,192 JSON nodes are accepted")
          (check (not (parse-accepted-p (%openrouter-node-boundary-json 255)))
                 "the 8,193rd JSON node is rejected")
          (check (parse-accepted-p (%openrouter-flat-object-json 256))
                 "exactly 256 keys in one object are accepted")
          (check (not (parse-accepted-p (%openrouter-flat-object-json 257)))
                 "the 257th key in one object is rejected")
          (check (parse-accepted-p (%openrouter-flat-array-json 256))
                 "exactly 256 elements in one array are accepted")
          (check (not (parse-accepted-p (%openrouter-flat-array-json 257)))
                 "the 257th element in one array is rejected")
          (check (parse-accepted-p
                  (format nil "\"~A\"" (make-string 65536
                                                    :initial-element #\s)))
                 "exactly 65,536 characters in one JSON string are accepted")
          (check (not
                  (parse-accepted-p
                   (format nil "\"~A\"" (make-string 65537
                                                     :initial-element #\s))))
                 "the 65,537th JSON string character is rejected"))
        ;; Tool argument JSON has its own UTF-8 limit.  A valid empty object
        ;; padded with JSON whitespace reaches the boundary without changing
        ;; its recognized schema.
        (let* ((base "{}")
               (exact-arguments
                 (concatenate 'string base
                              (make-string (- 65536 (length base))
                                           :initial-element #\Space)))
               (oversized-arguments
                 (concatenate 'string exact-arguments " ")))
          (multiple-value-bind (args recognized-name)
              (anuna-imago::%openai-args->plist
               "openrouter-boundary-target" exact-arguments)
            (check (null args)
                   "exactly 65,536 argument octets parse as the empty schema")
            (check (anuna-imago::%tool-name-equal-p
                    recognized-name 'anuna-imago::openrouter-boundary-target)
                   "exact-boundary arguments retain the registered identity"))
          (multiple-value-bind (args ignored-name)
              (anuna-imago::%openai-args->plist
               "openrouter-boundary-target" oversized-arguments)
            (declare (ignore ignored-name))
            (check (eq anuna-imago::*invalid-tool-arguments-marker*
                       (first args))
                   "the 65,537th argument octet produces the inert marker"))
          (let ((frames
                  (fetch
                   (%openrouter-test-tool-body
                    (list (%openrouter-test-call
                           "argument-boundary" :arguments exact-arguments))))))
            (check (= 1 (count :tool-use frames
                               :key (lambda (frame)
                                      (and (consp frame) (first frame)))))
                   "exact-boundary argument text yields one recognized call"))
          (run-agent
           (%openrouter-test-tool-body
            (list (%openrouter-test-call
                   "argument-overflow" :arguments oversized-arguments)))))
        ;; Identifier and name token bounds are independent of body size.
        (let* ((id-256 (make-string 256 :initial-element #\i))
               (id-257 (concatenate 'string id-256 "i"))
               (valid-frames
                 (fetch (%openrouter-test-tool-body
                         (list (%openrouter-test-call id-256)))))
               (invalid-frames
                 (fetch (%openrouter-test-tool-body
                         (list (%openrouter-test-call id-257))))))
          (check (= 1 (count :tool-use valid-frames
                             :key (lambda (frame)
                                    (and (consp frame) (first frame)))))
                 "a 256-character tool-call ID is accepted")
          (check (null (%frame-of-kind :tool-use invalid-frames))
                 "a 257-character tool-call ID rejects the response"))
        (let* ((name-128 (make-string 128 :initial-element #\n))
               (name-129 (concatenate 'string name-128 "n"))
               (long-tool-name (make-symbol (string-upcase name-128))))
          (register-tool!
           (make-tool :name long-tool-name
                      :schema nil
                      :handler (lambda (args)
                                 (declare (ignore args))
                                 (incf handler-calls)
                                 :must-not-run)))
          (unwind-protect
               (let ((valid-frames
                       (fetch (%openrouter-test-tool-body
                               (list (%openrouter-test-call
                                      "long-name" :name name-128)))))
                     (invalid-frames
                       (fetch (%openrouter-test-tool-body
                               (list (%openrouter-test-call
                                      "longer-name" :name name-129))))))
                 (check (= 1 (count :tool-use valid-frames
                                    :key (lambda (frame)
                                           (and (consp frame) (first frame)))))
                        "a 128-character registered tool name is accepted")
                 (check (null (%frame-of-kind :tool-use invalid-frames))
                        "a 129-character tool name rejects the response"))
            (unregister-tool! long-tool-name)))
        (let ((required-tool-name
                (make-symbol "OPENROUTER-REQUIRED-TARGET")))
          (register-tool!
           (make-tool :name required-tool-name
                      :schema '((:needed :type :integer :required-p t))
                      :handler (lambda (args)
                                 (declare (ignore args))
                                 (incf handler-calls)
                                 :must-not-run)))
          (unwind-protect
               (multiple-value-bind (args ignored-name)
                   (anuna-imago::%openai-args->plist
                    "openrouter-required-target" "{}")
                 (declare (ignore ignored-name))
                 (check (eq anuna-imago::*invalid-tool-arguments-marker*
                            (first args))
                        "a missing required schema argument is inert"))
            (unregister-tool! required-tool-name)))
        ;; HTTP success is inclusive at 200 and 299.  Adjacent statuses cannot
        ;; be overridden by an otherwise actionable body.
        (let ((action-body
                (%openrouter-test-tool-body
                 (list (%openrouter-test-call "status-boundary")))))
          (dolist (status '(200 299))
            (check (= 1 (count :tool-use (fetch action-body status)
                               :key (lambda (frame)
                                      (and (consp frame) (first frame)))))
                   (format nil "HTTP ~D admits the recognized response" status)))
          (dolist (status '(199 300))
            (check (null (%frame-of-kind :tool-use (fetch action-body status)))
                   (format nil "HTTP ~D rejects response semantics" status))))
        ;; Recognition ceilings are checked before response parsing or action.
        (let ((limit-symbol
                (find-symbol "+OPENROUTER-MAXIMUM-RESPONSE-OCTETS+"
                             :anuna-imago)))
          (progv (list limit-symbol) (list 1)
            (run-agent (%openrouter-test-tool-body
                        (list (%openrouter-test-call "oversized-body"))))))
        (let ((limit-symbol
                (find-symbol "+OPENROUTER-MAXIMUM-ARGUMENT-OCTETS+"
                             :anuna-imago)))
          (progv (list limit-symbol) (list 1)
            (let ((frames
                    (fetch
                     (%openrouter-test-tool-body
                      (list (%openrouter-test-call "oversized-arguments"))))))
              (let ((tool-frame (%frame-of-kind :tool-use frames)))
                (check (and tool-frame
                            (eq anuna-imago::*invalid-tool-arguments-marker*
                                (first (fourth tool-frame))))
                       "oversized arguments become the inert invalid marker"))
              (run-agent
               (%openrouter-test-tool-body
                (list (%openrouter-test-call "oversized-arguments-loop")))))))
        ;; The production HTTP seam returns a binary stream.  Pad a valid
        ;; response to the exact 1 MiB boundary, then cross it by one byte;
        ;; both streams must be closed and only the exact-boundary body parses.
        (let* ((base (%openrouter-test-stop-body))
               (limit (* 1024 1024))
               (padding (- limit
                           (length (sb-ext:string-to-octets
                                    base :external-format :utf-8))))
               (exact-text (concatenate 'string base
                                        (make-string padding
                                                     :initial-element #\Space)))
               (exact-octets (sb-ext:string-to-octets
                              exact-text :external-format :utf-8))
               (oversized-octets
                 (concatenate '(vector (unsigned-byte 8)) exact-octets #(32))))
          (multiple-value-bind (frames stream) (fetch-stream exact-octets)
            (check (eq :done (car (last frames)))
                   "an exact-boundary binary response stream is accepted")
            (check (not (open-stream-p stream))
                   "the accepted response stream is closed"))
          (multiple-value-bind (frames stream) (fetch-stream oversized-octets)
            (check (null (%frame-of-kind :tool-use frames))
                   "one streamed octet over the response limit is inert")
            (check (not (open-stream-p stream))
                   "the rejected response stream is closed")))
        ;; Deterministic arbitrary-input fuzz: the fetch boundary always
        ;; returns a terminal, non-action sequence and never signals outward.
        (let ((state #x0badcafe)
              (alphabet "{}[],:\\\"nulltruefalse012xyz "))
          (labels ((next (limit)
                     (setf state
                           (mod (+ (* state 1664525) 1013904223) #x100000000))
                     (mod state limit)))
            (loop repeat 500 do
              (let ((body (make-string (next 256))))
                (dotimes (offset (length body))
                  (setf (char body offset)
                        (char alphabet (next (length alphabet)))))
                (let ((frames (fetch body)))
                  (unless (and (eq :done (car (last frames)))
                               (null (%frame-of-kind :tool-use frames)))
                    (setf all-safe-p nil))))))))
      (check (zerop handler-calls)
             "malformed, ambiguous, oversized, and non-2xx data invoke no handler")
      (check all-safe-p
             "500 fuzzed response bodies produce only bounded terminal errors")
      (check (null (find-symbol (string-upcase unknown-name) :anuna-imago))
             "provider-controlled tool names are never interned")
      (check (null (find-symbol (string-upcase unknown-name) :keyword)))
      (unregister-tool! 'anuna-imago::openrouter-boundary-target)
      (check (equal tools-before (sort (mapcar #'symbol-name (list-tools)) #'string<))
             "the tool registry is unchanged after the boundary corpus")
      (check (equal packages-before (%openrouter-package-registry-snapshot))
             "the package registries are unchanged after the boundary corpus"))))

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
    (test-openrouter-closed-response-grammar)
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
