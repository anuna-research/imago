;;;; tools.lisp — tool definition, registry, schema conversion (CON-004)
;;;;
;;;; A tool is a named, schema-typed handler that an agent's LLM provider
;;;; can call. The 2k harness keeps tool registration provider-agnostic:
;;;; the schema is internal CL data; the JSON-Schema conversion produces
;;;; CL nested alists (not strings) so we don't pull in a JSON library
;;;; until M8 (provider drivers) actually needs to serialise.
;;;;
;;;; Live redefinition: `define-tool` is a thin wrapper around register-tool!
;;;; which overwrites by name. Re-defining a tool replaces its handler;
;;;; the next dispatch sees the new handler (REQ-004 substrate).

(in-package #:anuna-imago)

;; ---------------------------------------------------------------- types ---

(defparameter *valid-permissions*
  '(:read :write :execute :sensitive)
  "Permission categories per CON-004.")

(defparameter *valid-param-types*
  '(:string :integer :number :boolean :object :array)
  "Parameter type keywords accepted in tool schemas. Maps to JSON Schema types.")

(defstruct tool
  (name        nil :type symbol)
  (description ""  :type string)
  (permission  :read :type keyword)
  (schema      nil :type list)
  (handler     nil :type (or function null)))

;; ---------------------------------------------------------- registry ---

(defvar *tool-registry* (make-hash-table :test 'eq)
  "Map: tool-name (symbol) → TOOL struct.")

(defvar *tool-registry-lock* (sb-thread:make-mutex :name "tool-registry"))

(define-condition unauthorized-tool-call (error)
  ((name :initarg :name :reader unauthorized-tool-call-name))
  (:report (lambda (condition stream)
             (format stream "Tool ~S is not authorized for the current agent."
                     (unauthorized-tool-call-name condition)))))

;; ---------------------------------------------------- validation ---

(defun %validate-tool-spec (name description permission schema)
  "Signal an error if any field is malformed. Caller passes raw user input."
  (check-type name symbol)
  (check-type description string)
  (unless (member permission *valid-permissions*)
    (error "Tool ~A: permission ~S not in ~S" name permission *valid-permissions*))
  (dolist (spec schema)
    (unless (and (listp spec) (>= (length spec) 1) (symbolp (first spec)))
      (error "Tool ~A: malformed schema entry ~S" name spec))
    (let ((type (getf (rest spec) :type)))
      (when type
        (unless (member type *valid-param-types*)
          (error "Tool ~A: param ~S type ~S not in ~S"
                 name (first spec) type *valid-param-types*))))))

;; ---------------------------------------------------- registration ---

(defun register-tool! (tool)
  "Insert or replace TOOL in the registry. Validates first."
  (%validate-tool-spec (tool-name tool)
                       (tool-description tool)
                       (tool-permission tool)
                       (tool-schema tool))
  (sb-thread:with-mutex (*tool-registry-lock*)
    (setf (gethash (tool-name tool) *tool-registry*) tool))
  (tool-name tool))

(defun unregister-tool! (name)
  "Remove tool NAME from the registry. Returns T if removed, NIL if absent.
Accepts symbol, keyword, or string."
  (let ((normalized (%normalize-tool-name name)))
    (sb-thread:with-mutex (*tool-registry-lock*)
      (let ((had (nth-value 1 (gethash normalized *tool-registry*))))
        (remhash normalized *tool-registry*)
        had))))

(defun %normalize-tool-name (name)
  "Coerce NAME (symbol, keyword, or string) to the canonical registry key
— a non-keyword symbol in the :anuna-imago package. Provider drivers
hand us strings or keywords (e.g. Anthropic's parser interns
\"harness-version\" as :HARNESS-VERSION); the registry stores symbols
from define-tool. This normalisation lets keyword/string lookups
succeed."
  (cond
    ((and (symbolp name) (not (keywordp name))) name)
    ((keywordp name)
     (or (find-symbol (symbol-name name) :anuna-imago) name))
    ((stringp name)
     (or (find-symbol (string-upcase name) :anuna-imago)
         (intern (string-upcase name) :anuna-imago)))
    (t name)))

(defun find-tool (name)
  "Return the TOOL struct registered under NAME, or NIL.
Accepts symbol, keyword, or string — see %normalize-tool-name."
  (sb-thread:with-mutex (*tool-registry-lock*)
    (gethash (%normalize-tool-name name) *tool-registry*)))

(defun list-tools ()
  "Snapshot of registered tool names."
  (sb-thread:with-mutex (*tool-registry-lock*)
    (loop for k being the hash-keys of *tool-registry* collect k)))

(defun clear-all-tools ()
  "Wipe the registry. Used by tests."
  (sb-thread:with-mutex (*tool-registry-lock*)
    (clrhash *tool-registry*)))

;; ---------------------------------------------------- define-tool macro ---

(defmacro define-tool (name &key (description "") (permission :read) schema handler)
  "Define and register a tool.

  (define-tool get-weather
    :description \"Get current weather.\"
    :permission  :read
    :schema      ((:location :type :string :required-p t :description \"City\"))
    :handler     (lambda (args) (format nil \"~A: sunny\" (getf args :location))))"
  `(register-tool!
    (make-tool :name ',name
               :description ,description
               :permission ,permission
               :schema ',schema
               :handler ,handler)))

;; ---------------------------------------------------- dispatch ---

(defun %tool-name-equal-p (left right)
  "Compare provider tool-name designators without trusting package identity."
  (let ((left-name (typecase left
                     (symbol (symbol-name left))
                     (string left)))
        (right-name (typecase right
                      (symbol (symbol-name right))
                      (string right))))
    (and left-name right-name (string-equal left-name right-name))))

(defun %authorized-agent-tool-name (tool-name)
  "Return the allowlisted registry designator and authorization status."
  (cond
    ((null *current-agent*) (values tool-name t))
    (t
     (let ((allowed (find tool-name (agent-tools *current-agent*)
                          :test #'%tool-name-equal-p)))
       (values (or allowed tool-name) (not (null allowed)))))))

(defun dispatch-tool! (name args)
  "Look up tool NAME and invoke its handler with ARGS (a plist).
Returns whatever the handler returns; signals if tool is not registered or
has no handler."
  (multiple-value-bind (dispatch-name authorized-p)
      (%authorized-agent-tool-name name)
    (unless authorized-p
      (error 'unauthorized-tool-call :name name))
    (let ((tool (find-tool dispatch-name)))
      (cond
        ((null tool)
         (error "dispatch-tool!: no tool registered as ~S" dispatch-name))
        ((null (tool-handler tool))
         (error "dispatch-tool!: tool ~S has no handler" dispatch-name))
        (t (funcall (tool-handler tool) args))))))

;; ---------------------------------- schema → JSON-Schema (CL data) ---

(defun %param-key (sym)
  "Render a CL keyword/symbol parameter name as the JSON property key."
  (string-downcase (symbol-name sym)))

(defun %type-string (kw)
  "Render a type keyword as the JSON Schema type string."
  (string-downcase (symbol-name kw)))

(defun schema->json-schema (schema)
  "Convert an internal SCHEMA to JSON-Schema-shaped CL data:

  ((:type . \"object\")
   (:properties . ((\"param\" . ((:type . \"string\") (:description . \"...\"))) ...))
   (:required . (\"param1\" ...)))

Returned as nested alists; serialisation to a JSON string is deferred to
the provider driver (M8). This keeps the tool registry provider-agnostic
and zero-dep."
  (let ((properties nil)
        (required   nil))
    (dolist (spec schema)
      (destructuring-bind (param-name &key type required-p description) spec
        (let ((key  (%param-key param-name))
              (prop nil))
          (when type
            (push (cons :type (%type-string type)) prop))
          (when description
            (push (cons :description description) prop))
          (push (cons key (nreverse prop)) properties)
          (when required-p
            (push key required)))))
    (list (cons :type "object")
          (cons :properties (nreverse properties))
          (cons :required (nreverse required)))))

(defun json-schema->schema (json-data)
  "Reverse of schema->json-schema. Lossless round-trip for the keys
:type :required-p :description (param names round-trip via case-insensitive
keyword-intern; description-less / type-less params are preserved)."
  (let* ((properties (cdr (assoc :properties json-data)))
         (required   (cdr (assoc :required json-data)))
         (required-set required))
    (mapcar
     (lambda (prop)
       (let* ((key      (car prop))
              (def      (cdr prop))
              (type-str (cdr (assoc :type def)))
              (desc     (cdr (assoc :description def)))
              (param    (intern (string-upcase key) :keyword))
              (req-p    (and required-set (member key required-set :test #'string=) t)))
         (append (list param)
                 (when type-str
                   (list :type (intern (string-upcase type-str) :keyword)))
                 (list :required-p req-p)
                 (when desc
                   (list :description desc)))))
     properties)))

;; ----------------------------------- tool → provider tool-call descriptor ---

(defun tool->anthropic-descriptor (tool)
  "Render TOOL in the shape Anthropic Messages API expects (as CL data;
serialise in M8). Output:

  ((:name . \"get-weather\")
   (:description . \"...\")
   (:input_schema . <schema->json-schema output>))"
  (list (cons :name (string-downcase (symbol-name (tool-name tool))))
        (cons :description (tool-description tool))
        (cons :input_schema (schema->json-schema (tool-schema tool)))))
