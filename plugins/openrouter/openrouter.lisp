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
    "Default: forward to dexador. Tests rebind this to return canned data."
    (dex:post url :headers headers :content content))
  "Function (URL &key HEADERS CONTENT) → (values BODY-STRING STATUS-CODE).
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

(defmethod build-request ((p openrouter-provider) message agent)
  (let* ((content (or (and (listp message) (ask-content message))
                      (princ-to-string message)))
         (messages-vec
           (let ((msgs nil))
             ;; System prompt rides as a system message, NOT a separate field.
             (when (and (slot-boundp agent 'system-prompt)
                        (stringp (agent-system-prompt agent))
                        (not (string= "" (agent-system-prompt agent))))
               (push (%ht "role" "system" "content" (agent-system-prompt agent))
                     msgs))
             (push (%ht "role" "user" "content" content) msgs)
             (coerce (nreverse msgs) 'vector)))
         (req (%ht "model" (openrouter-model p)
                   "max_tokens" (openrouter-max-tokens p)
                   "messages" messages-vec)))
    (when (openrouter-temperature p)
      (setf (gethash "temperature" req) (openrouter-temperature p)))
    (let ((tool-specs
            (remove nil
                    (mapcar (lambda (n) (let ((tool (find-tool n)))
                                          (when tool (%tool->openai-ht tool))))
                            (agent-tools agent)))))
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

(defun %openai-args->plist (args-string)
  "Tool call arguments arrive as a JSON STRING (per OpenAI spec). Parse
it back to a plist, gracefully degrading to (:_raw <string>) if the
string isn't valid JSON."
  (cond
    ((null args-string) nil)
    ((not (stringp args-string)) nil)
    (t (handler-case (%hash->plist (com.inuoe.jzon:parse args-string))
         (error () (list :_raw args-string))))))

(defun %openrouter-response->frames (response-ht)
  "Walk choices[0].message and produce canonical frames followed by :done.

OpenAI shape:
  choices[0].message.content       → (:text …)
  choices[0].message.tool_calls[*] → (:tool-use ID NAME ARGS)
  choices[0].finish_reason='error' → (:error …)"
  (let* ((choices (gethash "choices" response-ht))
         (frames  nil))
    (when (and choices (or (vectorp choices) (listp choices)))
      (let* ((choice (elt (if (listp choices) (coerce choices 'vector) choices) 0))
             (message (gethash "message" choice))
             (text (and message (gethash "content" message)))
             (tool-calls (and message (gethash "tool_calls" message))))
        (when (and (stringp text) (not (string= text "")))
          (push (list :text text) frames))
        (when (and tool-calls (or (vectorp tool-calls) (listp tool-calls)))
          (loop for tc across (if (listp tool-calls)
                                  (coerce tool-calls 'vector)
                                  tool-calls)
                for fn = (gethash "function" tc)
                for id = (gethash "id" tc)
                for name = (and fn (gethash "name" fn))
                for args-str = (and fn (gethash "arguments" fn))
                when name
                  do (push (list :tool-use
                                 id
                                 (intern (string-upcase name) :keyword)
                                 (%openai-args->plist args-str))
                           frames)))
        (let ((finish (gethash "finish_reason" choice)))
          (when (string= finish "error")
            (push (list :error (gethash "error" response-ht)) frames)))))
    ;; Top-level error envelope (auth failure, model not found, etc.)
    (let ((err (gethash "error" response-ht)))
      (when err
        (push (list :error (list :provider "openrouter"
                                 :status :api-error
                                 :body (if (hash-table-p err)
                                           (%hash->plist err)
                                           err)))
              frames)))
    (nreverse (cons :done frames))))

;; ----------------------------------------------- stream! ---

(defmethod provider-stream! ((p openrouter-provider) agent message)
  "POST the request, parse JSON, build the frame list, return as a closure
matching the stub provider's calling convention."
  (let* ((frames (%openrouter-fetch-and-parse p (build-request p message agent)))
         (cell   (cons nil frames)))
    (lambda () (pop (cdr cell)))))

(defun %openrouter-fetch-and-parse (provider request-ht)
  "POST REQUEST-HT to the OpenRouter chat completions endpoint; parse the
response and return the canonical frame list. Errors from the HTTP layer
surface as (:error PLIST) and :done so the turn-loop can recover."
  (let* ((url (concatenate 'string (openrouter-base-url provider) "/chat/completions"))
         (headers (auth-headers provider))
         (body (com.inuoe.jzon:stringify request-ht)))
    (handler-case
        (let ((response-body (funcall *openrouter-http-post*
                                      url :headers headers :content body)))
          (%openrouter-response->frames (com.inuoe.jzon:parse response-body)))
      (error (c)
        (list (list :error (list :provider "openrouter"
                                 :status :request-failed
                                 :body (princ-to-string c)))
              :done)))))
