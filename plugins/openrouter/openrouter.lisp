;;;; providers/openrouter.lisp — OpenRouter (OpenAI-compatible) driver
;;;;
;;;; OpenRouter exposes most frontier models behind one OpenAI-compatible
;;;; Chat Completions endpoint at https://openrouter.ai/api/v1. This driver
;;;; lets imago agents use any OpenRouter-served model — Anthropic, OpenAI,
;;;; Google, Z.ai (GLM), Mistral, Meta, Qwen, etc. — without a model-
;;;; specific provider per family.
;;;;
;;;; Wire shape parallels providers/anthropic.lisp:
;;;;   - %ht / %hash->plist helpers
;;;;   - build-request, auth-headers, provider-stream! defmethods
;;;;   - %openrouter-http-post seam for tests
;;;;   - register-credential-eraser! at instance init for :clean t
;;;;
;;;; Two API differences vs Anthropic:
;;;;
;;;; 1. System prompt rides as the first messages[] element with
;;;;    role="system", not a separate "system" key.
;;;; 2. Tool calls round-trip as JSON strings inside
;;;;    choices[*].message.tool_calls[*].function.arguments — we parse
;;;;    these back to plists in %openrouter-response->frames.
;;;;
;;;; v0.1 implements the non-streaming path; SSE streaming via
;;;; /chat/completions stream=true is deferred along with Anthropic SSE.
;;;;
;;;; Usage:
;;;;   (let ((p (make-openrouter-provider
;;;;             :model "z-ai/glm-5.1"
;;;;             :app-name "imago-experiment"
;;;;             :site-url "https://example.com")))
;;;;     (make-instance 'agent ... :provider p :tools '(harness-eval ...)))

(in-package #:anuna-imago)

;; ----------------------------------------------------- HTTP indirection ---

(defvar *openrouter-http-post*
  (lambda (url &key headers content)
    "Default: request a binary stream so the caller controls body allocation."
    (dex:post url :headers headers :content content
                  :want-stream t :force-binary t))
  "Function (URL &key HEADERS CONTENT) → (values BODY STATUS-CODE), where
BODY is a binary stream in production or a string in tests.
Bind to a stub in tests so the OpenRouter driver doesn't need a live key.")

;; ----------------------------------------------------- class ---

(defclass openrouter-provider (provider)
  ((api-key    :initarg :api-key    :accessor openrouter-api-key
               :initform nil
               :documentation "Inline override; falls back to env at request time.")
   (model      :initarg :model      :reader openrouter-model
               :initform "z-ai/glm-5.1"
               :documentation "OpenRouter model slug, e.g. \"z-ai/glm-5.1\", \"anthropic/claude-opus-4-7\", \"openai/gpt-4o\". See https://openrouter.ai/models.")
   (base-url   :initarg :base-url   :reader openrouter-base-url
               :initform "https://openrouter.ai/api/v1")
   (max-tokens :initarg :max-tokens :reader openrouter-max-tokens
               :initform 4096)
   (temperature :initarg :temperature :reader openrouter-temperature
                :initform nil
                :documentation "Optional sampling temperature; nil → provider default.")
   (site-url   :initarg :site-url   :reader openrouter-site-url
               :initform nil
               :documentation "Optional HTTP-Referer header — appears on the OpenRouter dashboard.")
   (app-name   :initarg :app-name   :reader openrouter-app-name
               :initform nil
               :documentation "Optional X-Title header — appears on the OpenRouter dashboard.")))

(defmethod provider-name ((p openrouter-provider)) "openrouter")

(defun make-openrouter-provider (&key api-key model base-url max-tokens
                                       temperature site-url app-name)
  "Build an openrouter-provider. API key falls back to OPENROUTER_API_KEY
env var if :api-key is omitted. :model accepts any OpenRouter model slug.
:site-url and :app-name surface in the OpenRouter dashboard."
  (apply #'make-instance 'openrouter-provider
         (append (when api-key     (list :api-key api-key))
                 (when model       (list :model model))
                 (when base-url    (list :base-url base-url))
                 (when max-tokens  (list :max-tokens max-tokens))
                 (when temperature (list :temperature temperature))
                 (when site-url    (list :site-url site-url))
                 (when app-name    (list :app-name app-name)))))

;; ----------------------------------------------- credential cleanup ---

(defun openrouter-clear-credentials! (provider)
  "Zero out the api-key slot. Called by :clean t pre-save-clean."
  (setf (openrouter-api-key provider) nil))

(defmethod initialize-instance :after ((p openrouter-provider) &key)
  (register-credential-eraser!
   (lambda () (openrouter-clear-credentials! p))))

;; ----------------------------------------------- tool conversion ---

(defun %tool->openai-ht (tool)
  "Convert TOOL to the hash-table shape OpenAI-compatible APIs expect:
  {\"type\": \"function\",
   \"function\": {\"name\": ..., \"description\": ...,
                  \"parameters\": <JSON Schema object>}}"
  (let* ((desc        (tool->anthropic-descriptor tool))   ; reuse the converter
         (name-str    (cdr (assoc :name desc)))
         (description (cdr (assoc :description desc)))
         (schema      (cdr (assoc :input_schema desc)))
         (parameters
           (%ht "type"       (cdr (assoc :type schema))
                "properties" (%schema-properties->ht (cdr (assoc :properties schema)))
                "required"   (coerce (cdr (assoc :required schema)) 'vector))))
    (%ht "type" "function"
         "function" (%ht "name"        name-str
                         "description" description
                         "parameters"  parameters))))

;; ----------------------------------------------- build-request ---

(defun %openrouter-tool-results-content-p (content)
  (and (consp content)
       (eq :openrouter-tool-results (first content))))

(defun %openrouter-message->wire (message)
  "Translate one canonical history message to OpenAI wire messages."
  (let ((role (getf message :role))
        (content (getf message :content)))
    (cond
      ;; Response parsing retains the complete assistant message so its
      ;; tool_calls array can be sent back byte-for-byte on the next step.
      ((and (stringp role) (string= role "assistant")
            (hash-table-p content))
       (list content))
      ;; DRIVE-STREAM represents provider feedback as a canonical user
      ;; message. Expand our tagged content into OpenAI role=tool messages.
      ((%openrouter-tool-results-content-p content)
       (copy-list (rest content)))
      (t
       (list (%ht "role" role "content" content))))))

(defun %openrouter-request-messages (message agent)
  "Build the complete OpenAI messages vector without flattening history."
  (let ((messages
          (cond
            ((%messages-list-p message)
             (mapcan #'%openrouter-message->wire message))
            (t
             (list (%ht "role" "user"
                        "content"
                        (or (and (listp message) (ask-content message))
                            (princ-to-string message))))))))
    (when (and (slot-boundp agent 'system-prompt)
               (stringp (agent-system-prompt agent))
               (not (string= "" (agent-system-prompt agent))))
      (push (%ht "role" "system" "content" (agent-system-prompt agent))
            messages))
    (coerce messages 'vector)))

(defmethod build-request ((p openrouter-provider) message agent)
  (let* ((req (%ht "model" (openrouter-model p)
                   "max_tokens" (openrouter-max-tokens p)
                   "messages" (%openrouter-request-messages message agent))))
    (when (openrouter-temperature p)
      (setf (gethash "temperature" req) (openrouter-temperature p)))
    (let ((tool-specs
            (remove nil
                    (mapcar (lambda (n) (let ((tool (find-tool n)))
                                          (when tool (%tool->openai-ht tool))))
                            (%effective-agent-tool-names agent)))))
      (when tool-specs
        (setf (gethash "tools" req) (coerce tool-specs 'vector))))
    req))

;; ----------------------------------------------- auth-headers ---

(defmethod auth-headers ((p openrouter-provider))
  (let ((key (or (openrouter-api-key p)
                 (uiop:getenv "OPENROUTER_API_KEY")
                 (error "OpenRouter API key not set: pass :api-key to make-openrouter-provider or set OPENROUTER_API_KEY env."))))
    (let ((headers
            (list (cons "Authorization" (concatenate 'string "Bearer " key))
                  (cons "Content-Type"  "application/json"))))
      (when (openrouter-site-url p)
        (push (cons "HTTP-Referer" (openrouter-site-url p)) headers))
      (when (openrouter-app-name p)
        (push (cons "X-Title" (openrouter-app-name p)) headers))
      headers)))

;; ----------------------------------------------- response → frames ---

(defparameter +openrouter-maximum-response-octets+ (* 1024 1024))
(defparameter +openrouter-maximum-argument-octets+ (* 64 1024))
(defparameter +openrouter-maximum-json-depth+ 32)
(defparameter +openrouter-maximum-json-nodes+ 8192)
(defparameter +openrouter-maximum-object-keys+ 256)
(defparameter +openrouter-maximum-array-elements+ 256)
(defparameter +openrouter-maximum-string-characters+ 65536)
(defparameter +openrouter-maximum-tool-calls+ 16)
(defparameter +openrouter-maximum-identifier-characters+ 256)
(defparameter +openrouter-maximum-tool-name-characters+ 128)

(defun %openrouter-json-octet-length (text)
  (length (sb-ext:string-to-octets text :external-format :utf-8)))

(defun %openrouter-scan-json! (text maximum-octets context)
  "Use Jzon's streaming recognizer to enforce bounds and duplicate-key denial."
  (unless (stringp text) (error "~A is not a JSON string." context))
  (when (> (%openrouter-json-octet-length text) maximum-octets)
    (error "~A exceeds its ~D-octet limit." context maximum-octets))
  (com.inuoe.jzon:with-parser
      (parser text :max-string-length +openrouter-maximum-string-characters+
                   :key-fn nil)
    (let ((stack nil) (nodes 0))
      (labels ((note-node ()
                 (when (> (incf nodes) +openrouter-maximum-json-nodes+)
                   (error "~A contains too many JSON nodes." context)))
               (note-array-value ()
                 (when (and stack (eq :array (first (first stack))))
                   (when (> (incf (second (first stack)))
                            +openrouter-maximum-array-elements+)
                     (error "~A contains an oversized JSON array." context))))
               (begin-container (kind)
                 (note-array-value)
                 (note-node)
                 (when (>= (length stack) +openrouter-maximum-json-depth+)
                   (error "~A exceeds the JSON depth limit." context))
                 (push (list kind 0
                             (and (eq kind :object)
                                  (make-hash-table :test 'equal)))
                       stack)))
        (loop
          (multiple-value-bind (event value) (com.inuoe.jzon:parse-next parser)
            (case event
              ((nil)
               (when stack (error "~A ended inside a JSON container." context))
               (return))
              (:begin-array (begin-container :array))
              (:begin-object (begin-container :object))
              (:object-key
               (unless (and stack (eq :object (first (first stack))))
                 (error "~A has a key outside an object." context))
               (note-node)
               (let ((keys (third (first stack))))
                 (when (gethash value keys)
                   (error "~A contains duplicate object key ~S." context value))
                 (setf (gethash value keys) t)
                 (when (> (incf (second (first stack)))
                          +openrouter-maximum-object-keys+)
                   (error "~A contains an oversized JSON object." context))))
              (:value (note-array-value) (note-node))
              (:end-array
               (unless (and stack (eq :array (first (first stack))))
                 (error "~A has mismatched JSON containers." context))
               (pop stack))
              (:end-object
               (unless (and stack (eq :object (first (first stack))))
                 (error "~A has mismatched JSON containers." context))
               (pop stack))))))))
  text)

(defun %openrouter-parse-json (text maximum-octets context)
  (%openrouter-scan-json! text maximum-octets context)
  (com.inuoe.jzon:parse text
                        :max-depth +openrouter-maximum-json-depth+
                        :max-string-length +openrouter-maximum-string-characters+
                        :key-fn nil))

(defun %openrouter-hash-shape! (value required allowed context)
  (unless (hash-table-p value) (error "~A must be a JSON object." context))
  (maphash (lambda (key ignored)
             (declare (ignore ignored))
             (unless (and (stringp key) (member key allowed :test #'string=))
               (error "~A contains unknown field ~S." context key)))
           value)
  (dolist (key required)
    (unless (nth-value 1 (gethash key value))
      (error "~A omits required field ~S." context key)))
  value)

(defun %openrouter-token-string-p (value maximum-length)
  (and (stringp value)
       (<= 1 (length value) maximum-length)
       (every (lambda (character)
                (let ((code (char-code character)))
                  (not (or (< code 32) (<= #x7f code #x9f)))))
              value)))

(defun %openrouter-registered-tool (wire-name)
  (let ((matches (remove-if-not
                  (lambda (name) (string-equal wire-name (symbol-name name)))
                  (list-tools))))
    (and (= 1 (length matches)) (find-tool (first matches)))))

(defun %openrouter-argument-type-p (value type)
  (case type
    (:string (stringp value))
    (:integer (integerp value))
    (:number (realp value))
    (:boolean (or (null value) (eq value t)))
    (:object (hash-table-p value))
    ;; Jzon maps JSON arrays to vectors, FALSE to NIL, and NULL to the symbol
    ;; NULL.  LISTP would therefore misclassify provider-controlled FALSE as
    ;; an empty array.
    (:array (vectorp value))
    (otherwise nil)))

(defun %openrouter-recognize-tool-arguments (wire-name parsed)
  (unless (hash-table-p parsed) (error "Tool arguments must be a JSON object."))
  (let ((tool (%openrouter-registered-tool wire-name)))
    (unless tool (error "Tool name is not present in the finite registry."))
    (let ((schema (tool-schema tool)) (recognized 0) (result nil))
      (dolist (spec schema)
        (let* ((parameter (first spec))
               (wire-key (string-downcase (symbol-name parameter))))
          (multiple-value-bind (value present-p) (gethash wire-key parsed)
            (when present-p
              (incf recognized)
              (unless (%openrouter-argument-type-p value (getf (rest spec) :type))
                (error "Tool argument ~S has the wrong JSON type." wire-key))
              (setf result (append result (list parameter value))))
            (when (and (getf (rest spec) :required-p) (not present-p))
              (error "Required tool argument ~S is absent." wire-key)))))
      (unless (= recognized (hash-table-count parsed))
        (error "Tool arguments contain a field outside the registered schema."))
      (values result (tool-name tool)))))

(defun %openai-args->plist (wire-name args-string)
  "Recognize bounded JSON arguments against the registered tool schema."
  (handler-case
      (%openrouter-recognize-tool-arguments
       wire-name
       (%openrouter-parse-json args-string +openrouter-maximum-argument-octets+
                               "OpenRouter tool arguments"))
    (error (condition)
      (values (list *invalid-tool-arguments-marker* (princ-to-string condition))
              wire-name))))

(defun %openrouter-finish-reason (finish)
  "Return canonical stop reason and whether FINISH was recognized."
  (cond
    ((and (stringp finish) (string= finish "stop"))
     (values :end-turn t))
    ((and (stringp finish) (string= finish "tool_calls"))
     (values :tool-use t))
    ((and (stringp finish) (string= finish "length"))
     (values :max-tokens t))
    ((and (stringp finish) (string= finish "error"))
     (values :error t))
    (t
     (values :error nil))))

(defun %openrouter-validate-token-details! (details allowed context)
  (%openrouter-hash-shape! details nil allowed context)
  (maphash
   (lambda (key value)
     (unless (and (integerp value) (not (minusp value)))
       (error "~A field ~S is not nonnegative." context key)))
   details))

(defun %openrouter-validate-usage! (usage present-p)
  (when present-p
    (%openrouter-hash-shape!
     usage nil
     '("prompt_tokens" "completion_tokens" "total_tokens" "cost"
       "is_byok" "prompt_tokens_details" "completion_tokens_details")
     "OpenRouter usage")
    (dolist (key '("prompt_tokens" "completion_tokens" "total_tokens"))
      (multiple-value-bind (value present-p) (gethash key usage)
        (when (and present-p (not (and (integerp value) (not (minusp value)))))
          (error "OpenRouter usage field ~S is not nonnegative." key))))
    (dolist (key '("prompt_tokens_details" "completion_tokens_details"))
      (multiple-value-bind (value present-p) (gethash key usage)
        (when (and present-p (not (or (hash-table-p value) (eq value 'null))))
          (error "OpenRouter usage detail ~S has the wrong type." key))))
    (multiple-value-bind (cost present-p) (gethash "cost" usage)
      (when (and present-p
                 (not (or (and (realp cost) (not (minusp cost)))
                          (eq cost 'null))))
        (error "OpenRouter usage cost has the wrong type.")))
    (multiple-value-bind (byok present-p) (gethash "is_byok" usage)
      (when (and present-p (not (or (null byok) (eq byok t))))
        (error "OpenRouter usage is_byok has the wrong type.")))
    (multiple-value-bind (details present-p)
        (gethash "prompt_tokens_details" usage)
      (when (and present-p (hash-table-p details))
        (%openrouter-validate-token-details!
         details '("cached_tokens" "audio_tokens" "video_tokens")
         "OpenRouter prompt token details")))
    (multiple-value-bind (details present-p)
        (gethash "completion_tokens_details" usage)
      (when (and present-p (hash-table-p details))
        (%openrouter-validate-token-details!
         details '("reasoning_tokens" "audio_tokens"
                   "accepted_prediction_tokens" "rejected_prediction_tokens")
         "OpenRouter completion token details")))))

(defun %openrouter-validate-root-metadata! (response)
  (multiple-value-bind (value present-p) (gethash "id" response)
    (when (and present-p
               (not (or (%openrouter-token-string-p
                         value +openrouter-maximum-identifier-characters+)
                        (eq value 'null))))
      (error "OpenRouter metadata field \"id\" is not a bounded identifier.")))
  (dolist (key '("object" "model" "system_fingerprint" "provider"))
    (multiple-value-bind (value present-p) (gethash key response)
      (when (and present-p (not (or (stringp value) (eq value 'null))))
        (error "OpenRouter metadata field ~S has the wrong type." key))))
  (multiple-value-bind (created present-p) (gethash "created" response)
    (when (and present-p
               (not (and (integerp created) (not (minusp created)))))
      (error "OpenRouter created timestamp has the wrong type."))))

(defun %openrouter-error-frames (status &rest fields)
  (list (list :error (append (list :provider "openrouter" :status status)
                             fields))
        :done))

(defun %openrouter-error-envelope-frames (response)
  (%openrouter-hash-shape!
   response '("error") '("error" "id" "request_id")
   "OpenRouter error envelope")
  (let ((error-value (gethash "error" response)))
    (%openrouter-hash-shape!
     error-value '("message") '("code" "message" "metadata")
     "OpenRouter error")
    (unless (stringp (gethash "message" error-value))
      (error "OpenRouter error message must be a string."))
    (dolist (key '("id" "request_id"))
      (multiple-value-bind (value present-p) (gethash key response)
        (when (and present-p
                   (not (or (%openrouter-token-string-p
                             value +openrouter-maximum-identifier-characters+)
                            (eq value 'null))))
          (error "OpenRouter error identifier ~S has the wrong type." key))))
    (multiple-value-bind (code present-p) (gethash "code" error-value)
      (when (and present-p
                 (not (or (stringp code) (integerp code) (eq code 'null))))
        (error "OpenRouter error code has the wrong type.")))
    (multiple-value-bind (metadata present-p) (gethash "metadata" error-value)
      (when (and present-p
                 (not (or (hash-table-p metadata) (eq metadata 'null))))
        (error "OpenRouter error metadata has the wrong type.")))
    (%openrouter-error-frames :api-error :body error-value)))

(defun %openrouter-tool-call->frame (tool-call seen-ids)
  (%openrouter-hash-shape!
   tool-call '("id" "type" "function") '("id" "type" "function")
   "OpenRouter tool call")
  (let ((id (gethash "id" tool-call))
        (type (gethash "type" tool-call))
        (function (gethash "function" tool-call)))
    (unless (%openrouter-token-string-p id +openrouter-maximum-identifier-characters+)
      (error "OpenRouter tool-call ID is invalid."))
    (when (gethash id seen-ids)
      (error "OpenRouter response repeats tool-call ID ~S." id))
    (setf (gethash id seen-ids) t)
    (unless (and (stringp type) (string= type "function"))
      (error "OpenRouter tool-call type is not function."))
    (%openrouter-hash-shape!
     function '("name" "arguments") '("name" "arguments")
     "OpenRouter tool function")
    (let ((wire-name (gethash "name" function))
          (arguments (gethash "arguments" function)))
      (unless (%openrouter-token-string-p
               wire-name +openrouter-maximum-tool-name-characters+)
        (error "OpenRouter tool name is invalid."))
      (multiple-value-bind (args recognized-name)
          (%openai-args->plist wire-name arguments)
        (list :tool-use id recognized-name args)))))

(defun %openrouter-response->frames (response-ht)
  "Recognize one closed success/error envelope before emitting action frames."
  (unless (hash-table-p response-ht)
    (error "OpenRouter response root must be a JSON object."))
  (let ((error-present-p (nth-value 1 (gethash "error" response-ht)))
        (choices-present-p (nth-value 1 (gethash "choices" response-ht))))
    (when (and error-present-p choices-present-p)
      (error "OpenRouter response ambiguously contains error and choices."))
    (when error-present-p
      (return-from %openrouter-response->frames
        (%openrouter-error-envelope-frames response-ht)))
    (%openrouter-hash-shape!
     response-ht '("choices")
     '("id" "object" "created" "model" "choices" "usage"
       "system_fingerprint" "provider")
     "OpenRouter success envelope")
    (%openrouter-validate-root-metadata! response-ht)
    (multiple-value-bind (usage present-p) (gethash "usage" response-ht)
      (%openrouter-validate-usage! usage present-p))
    (let ((choices (gethash "choices" response-ht)))
      (unless (and (vectorp choices) (= 1 (length choices)))
        (error "OpenRouter success requires exactly one choice."))
      (let* ((choice (elt choices 0)) (frames nil))
        (%openrouter-hash-shape!
         choice '("message" "finish_reason")
         '("index" "message" "finish_reason" "native_finish_reason" "logprobs")
         "OpenRouter choice")
        (multiple-value-bind (index present-p) (gethash "index" choice)
          (when (and present-p (not (and (integerp index) (not (minusp index)))))
            (error "OpenRouter choice index has the wrong type.")))
        (multiple-value-bind (logprobs present-p) (gethash "logprobs" choice)
          (when (and present-p (not (eq logprobs 'null)))
            (error "Unrequested OpenRouter logprobs are unsupported.")))
        (multiple-value-bind (native present-p)
            (gethash "native_finish_reason" choice)
          (when (and present-p
                     (not (or (stringp native) (eq native 'null))))
            (error "OpenRouter native finish reason has the wrong type.")))
        (let* ((message (gethash "message" choice))
               (finish (gethash "finish_reason" choice)))
          (%openrouter-hash-shape!
           message '("role" "content")
           '("role" "content" "tool_calls" "refusal" "reasoning")
           "OpenRouter assistant message")
          (unless (and (stringp (gethash "role" message))
                       (string= "assistant" (gethash "role" message)))
            (error "OpenRouter message role is not assistant."))
          (let ((text (gethash "content" message)))
            (unless (or (stringp text) (eq text 'null))
              (error "OpenRouter assistant content has the wrong type."))
            (when (and (stringp text) (plusp (length text)))
              (push (list :text text) frames)))
          (dolist (key '("refusal" "reasoning"))
            (multiple-value-bind (value present-p) (gethash key message)
              (when (and present-p
                         (not (or (stringp value) (eq value 'null))))
                (error "OpenRouter message field ~S has the wrong type." key))))
          (unless (stringp finish)
            (error "OpenRouter finish reason must be a string."))
          (let* ((tool-calls-present-p
                   (nth-value 1 (gethash "tool_calls" message)))
                 (tool-calls (gethash "tool_calls" message)))
            (if (string= finish "tool_calls")
                (progn
                  (unless (and tool-calls-present-p
                               (vectorp tool-calls)
                               (<= 1 (length tool-calls)
                                   +openrouter-maximum-tool-calls+))
                    (error "OpenRouter tool finish has an invalid call collection."))
                  (let ((seen-ids (make-hash-table :test 'equal)))
                    (map nil (lambda (tool-call)
                               (push (%openrouter-tool-call->frame tool-call seen-ids)
                                     frames))
                         tool-calls)))
                (when (and tool-calls-present-p
                           (not (and (vectorp tool-calls)
                                     (zerop (length tool-calls)))))
                  (error "OpenRouter non-tool finish contains tool calls."))))
          (push (list :assistant-content message) frames)
          (multiple-value-bind (stop-reason recognized-p)
              (%openrouter-finish-reason finish)
            (push (list :stop-reason stop-reason) frames)
            (unless recognized-p
              (push (list :error
                          (list :provider "openrouter"
                                :status :unknown-finish-reason
                                :finish-reason finish))
                    frames))
            (when (eq stop-reason :error)
              (push (list :error (list :provider "openrouter"
                                       :status :provider-error))
                    frames)))
          (nreverse (cons :done frames)))))))

;; ------------------------------------------ tool results round-trip ---

(defmethod tool-results-message-content ((p openrouter-provider) results)
  "Tag OpenAI role=tool messages for expansion by BUILD-REQUEST."
  (declare (ignore p))
  (cons
   :openrouter-tool-results
   (mapcar
    (lambda (result)
      (let* ((status (getf result :status))
             (content
               (cond
                 ((eq status :ok) (princ-to-string (getf result :value)))
                 ((eq status :error)
                  (format nil "ERROR: ~A" (getf result :error)))
                 ((eq status :vetoed) "VETOED by safety policy")
                 ((eq status :unauthorized) "UNAUTHORIZED by agent policy")
                 (t (princ-to-string result)))))
        (%ht "role" "tool"
             "tool_call_id" (getf result :id)
             "content" content)))
    results)))

;; ----------------------------------------------- stream! ---

(defmethod provider-stream! ((p openrouter-provider) agent message)
  "POST the request, parse JSON, build the frame list, return as a closure
matching the stub provider's calling convention."
  (let* ((frames (%openrouter-fetch-and-parse p (build-request p message agent)))
         (cell   (cons nil frames)))
    (lambda () (pop (cdr cell)))))

(defun %openrouter-bounded-response-string (body)
  "Materialize at most the configured response limit from BODY.

The production seam supplies an octet stream.  String bodies remain supported
for deterministic test seams, but are checked before parsing."
  (cond
    ((stringp body)
     (when (> (%openrouter-json-octet-length body)
              +openrouter-maximum-response-octets+)
       (error "OpenRouter HTTP body exceeds its recognition limit."))
     body)
    ((streamp body)
     (unwind-protect
          (progn
            (unless (nth-value
                     0 (subtypep (stream-element-type body)
                                 '(unsigned-byte 8)))
              (error "OpenRouter HTTP body stream is not binary."))
            (let* ((octets
                     (make-array
                      (1+ +openrouter-maximum-response-octets+)
                      :element-type '(unsigned-byte 8)))
                   (count (read-sequence octets body)))
              (when (> count +openrouter-maximum-response-octets+)
                (error "OpenRouter HTTP body exceeds its recognition limit."))
              (sb-ext:octets-to-string
               (subseq octets 0 count) :external-format :utf-8)))
       (close body)))
    (t (error "OpenRouter HTTP body is neither a string nor a binary stream."))))

(defun %openrouter-fetch-and-parse (provider request-ht)
  "POST REQUEST-HT to the OpenRouter chat completions endpoint; parse the
response and return the canonical frame list. Errors from the HTTP layer
surface as (:error PLIST) and :done so the turn-loop can recover."
  (let* ((url (concatenate 'string (openrouter-base-url provider) "/chat/completions"))
         (headers (auth-headers provider))
         (body (com.inuoe.jzon:stringify request-ht)))
    (multiple-value-bind (response-body status)
        (handler-case
            (funcall *openrouter-http-post* url :headers headers :content body)
          (error (condition)
            (return-from %openrouter-fetch-and-parse
              (%openrouter-error-frames :request-failed
                                        :body (princ-to-string condition)))))
      (handler-case
          (progn
            (when (and status
                       (not (and (integerp status) (<= 200 status 299))))
              (when (streamp response-body) (close response-body))
              (return-from %openrouter-fetch-and-parse
                (%openrouter-error-frames :http-error :http-status status)))
            (%openrouter-response->frames
             (%openrouter-parse-json
              (%openrouter-bounded-response-string response-body)
              +openrouter-maximum-response-octets+
              "OpenRouter response")))
        (error (condition)
          (%openrouter-error-frames :malformed-response
                                    :body (princ-to-string condition)))))))
