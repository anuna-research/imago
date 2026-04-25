;;;; providers/anthropic.lisp — Anthropic Messages API driver (CON-005)
;;;;
;;;; v0.1 implements the non-streaming path: POST one request, parse the
;;;; JSON response, walk content blocks, emit frames in order, then :done.
;;;; Streaming SSE is deferred — non-streaming is simpler, exercises the
;;;; CON-005 surface fully, and is the right shape for a 2k LOC budget.
;;;;
;;;; HTTP indirection: *ANTHROPIC-HTTP-POST* is the seam tests inject a
;;;; mock through. In production it forwards to dexador; tests bind it to
;;;; a function returning canned JSON. This avoids requiring a live API
;;;; key for M8 unit tests.
;;;;
;;;; Credentials: The api-key slot may be set explicitly at construction
;;;; time, or read lazily from ANTHROPIC_API_KEY at request time. Either
;;;; way, REGISTER-CREDENTIAL-ERASER! wires :clean t to clear the slot
;;;; before save-image! to prevent key leakage into shipped images.

(in-package #:anuna-imago)

;; ----------------------------------------------------- HTTP indirection ---

(defvar *anthropic-http-post*
  (lambda (url &key headers content)
    "Default: forward to dexador. Tests rebind this to return canned data."
    (dex:post url :headers headers :content content))
  "Function (URL &key HEADERS CONTENT) → (values BODY-STRING STATUS-CODE).
Bind to a stub in tests so M8 doesn't need a live API key.")

;; ----------------------------------------------------- class ---

(defclass anthropic-provider (provider)
  ((api-key    :initarg :api-key    :accessor anthropic-api-key
               :initform nil
               :documentation "Inline override; falls back to env at request time.")
   (model      :initarg :model      :reader anthropic-model
               :initform "claude-opus-4-7")
   (base-url   :initarg :base-url   :reader anthropic-base-url
               :initform "https://api.anthropic.com")
   (max-tokens :initarg :max-tokens :reader anthropic-max-tokens
               :initform 4096)
   (version    :initarg :version    :reader anthropic-version
               :initform "2023-06-01")))

(defmethod provider-name ((p anthropic-provider)) "anthropic")

(defun make-anthropic-provider (&key api-key model base-url max-tokens)
  (apply #'make-instance 'anthropic-provider
         (append (when api-key (list :api-key api-key))
                 (when model (list :model model))
                 (when base-url (list :base-url base-url))
                 (when max-tokens (list :max-tokens max-tokens)))))

;; ----------------------------------------------- credential cleanup ---

(defun anthropic-clear-credentials! (provider)
  "Zero out the api-key slot. Called by :clean t pre-save-clean."
  (setf (anthropic-api-key provider) nil))

;; Auto-register a credential eraser the first time a provider asks
(defmethod initialize-instance :after ((p anthropic-provider) &key)
  (register-credential-eraser!
   (lambda () (anthropic-clear-credentials! p))))

;; ----------------------------------------------- helpers ---

(defun %ht (&rest kvs)
  "Build a hash-table from alternating k/v. String keys."
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on kvs by #'cddr
          do (setf (gethash (typecase k
                              (string k)
                              (symbol (string-downcase (symbol-name k)))
                              (t (princ-to-string k)))
                            h)
                   v))
    h))

(defun %hash->plist (ht)
  "Convert a (string-keyed) hash-table to a plist with keyword keys."
  (let ((plist nil))
    (maphash (lambda (k v)
               (push v plist)
               (push (intern (string-upcase k) :keyword) plist))
             ht)
    plist))

;; ----------------------------------------------- tool conversion ---

(defun %schema-properties->ht (properties-alist)
  "Convert ((PROP-KEY . ((:type . T) (:description . D))) ...) to nested HT."
  (let ((h (make-hash-table :test 'equal)))
    (dolist (prop properties-alist)
      (let ((prop-h (make-hash-table :test 'equal)))
        (dolist (pair (cdr prop))
          (setf (gethash (string-downcase (symbol-name (car pair))) prop-h)
                (cdr pair)))
        (setf (gethash (car prop) h) prop-h)))
    h))

(defun %tool->anthropic-ht (tool)
  "Convert TOOL to the hash-table shape Anthropic Messages API expects."
  (let* ((desc (tool->anthropic-descriptor tool))
         (schema (cdr (assoc :input_schema desc))))
    (%ht "name" (cdr (assoc :name desc))
         "description" (cdr (assoc :description desc))
         "input_schema"
         (%ht "type" (cdr (assoc :type schema))
              "properties"
              (%schema-properties->ht (cdr (assoc :properties schema)))
              "required"
              (coerce (cdr (assoc :required schema)) 'vector)))))

;; ----------------------------------------------- build-request ---

(defgeneric build-request (provider message agent)
  (:documentation "Pure: produce the JSON-shaped request body (hash-table)."))

(defmethod build-request ((p anthropic-provider) message agent)
  (let* ((content (or (and (listp message) (ask-content message))
                      (princ-to-string message)))
         (req (%ht "model" (anthropic-model p)
                   "max_tokens" (anthropic-max-tokens p)
                   "messages" (vector
                               (%ht "role" "user"
                                    "content" content)))))
    (when (and (slot-boundp agent 'system-prompt)
               (stringp (agent-system-prompt agent))
               (not (string= "" (agent-system-prompt agent))))
      (setf (gethash "system" req) (agent-system-prompt agent)))
    (let ((tool-specs
            (remove nil
                    (mapcar (lambda (n) (let ((tool (find-tool n)))
                                          (when tool (%tool->anthropic-ht tool))))
                            (agent-tools agent)))))
      (when tool-specs
        (setf (gethash "tools" req) (coerce tool-specs 'vector))))
    req))

;; ----------------------------------------------- auth-headers ---

(defgeneric auth-headers (provider)
  (:documentation "Headers for the HTTP request."))

(defmethod auth-headers ((p anthropic-provider))
  (let ((key (or (anthropic-api-key p)
                 (uiop:getenv "ANTHROPIC_API_KEY")
                 (error "Anthropic API key not set: pass :api-key to make-anthropic-provider or set ANTHROPIC_API_KEY env."))))
    (list (cons "x-api-key"          key)
          (cons "anthropic-version"  (anthropic-version p))
          (cons "content-type"       "application/json"))))

;; ----------------------------------------------- response → frames ---

(defun %anthropic-response->frames (response-ht)
  "Walk the content blocks of a non-streaming Messages API response and
return a list of canonical frames followed by :done."
  (let ((content (gethash "content" response-ht))
        (frames  nil))
    (when (or (vectorp content) (listp content))
      (loop for block across (if (listp content) (coerce content 'vector) content)
            for type = (gethash "type" block)
            do (cond
                 ((string= type "text")
                  (push (list :text (gethash "text" block)) frames))
                 ((string= type "tool_use")
                  (push (list :tool-use
                              (gethash "id" block)
                              (intern (string-upcase (gethash "name" block))
                                      :keyword)
                              (%hash->plist (or (gethash "input" block)
                                                (make-hash-table))))
                        frames))
                 (t nil))))                  ; unknown block — skip
    (let ((stop-reason (gethash "stop_reason" response-ht)))
      (when (string= stop-reason "error")
        (push (list :error (gethash "error" response-ht)) frames)))
    (nreverse (cons :done frames))))

;; ----------------------------------------------- stream! ---

(defmethod provider-stream! ((p anthropic-provider) agent message)
  "POST the request, parse JSON, build the frame list, return as a closure
matching the stub provider's calling convention."
  (let* ((frames (%fetch-and-parse p (build-request p message agent)))
         (cell   (cons nil frames)))
    (lambda () (pop (cdr cell)))))

;; STREAM-NEXT-FRAME! on functions is already defined by providers/stub.lisp
;; — we reuse it here.

(defun %fetch-and-parse (provider request-ht)
  "POST REQUEST-HT to the provider's messages endpoint; return the parsed
response as a hash-table. Errors from the HTTP layer surface as a list
of frames containing (:error PLIST) and :done so the turn-loop can
recover."
  (let* ((url (concatenate 'string (anthropic-base-url provider) "/v1/messages"))
         (headers (auth-headers provider))
         (body (com.inuoe.jzon:stringify request-ht)))
    (handler-case
        (let ((response-body (funcall *anthropic-http-post*
                                      url :headers headers :content body)))
          (let ((parsed (com.inuoe.jzon:parse response-body)))
            (%anthropic-response->frames parsed)))
      (error (c)
        (list (list :error (list :provider "anthropic"
                                 :status :request-failed
                                 :body (princ-to-string c)))
              :done)))))
