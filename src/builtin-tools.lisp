;;;; builtin-tools.lisp — small set of introspection / utility tools
;;;;
;;;; Auto-registered when (asdf:load-system :imago) loads. Agents that
;;;; want them must list the name(s) in :tools to expose to the LLM;
;;;; agents that don't list them are unaffected.
;;;;
;;;; Stance discipline: this file ships ONLY introspection + small
;;;; utility tools. Capability-augmenting tools (file IO, shell exec,
;;;; HTTP fetch, web search) are deliberately NOT here — route those
;;;; via MCP or a per-project tool module. See SPEC-011 §"Stance".

(in-package #:anuna-imago)

;; ---------------------------------------------------------- handlers ---
;;
;; Each handler is a separate DEFUN so REQ-004 (live redefinition) works:
;; an operator at SLIME can redefine %TOOL-LIST-TOOLS and the next call
;; through harness-list-tools picks up the new behaviour.

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

;; ---------------------------------------------------------- registration ---

(defun install-builtin-tools! ()
  "Register the built-in tools. Idempotent — safe to re-call after
CLEAR-ALL-TOOLS. Auto-called when this file loads."
  (register-tool!
   (make-tool :name 'harness-list-tools
              :description "List the names of all tools currently registered with the harness."
              :permission  :read
              :schema      ()
              :handler     #'%tool-list-tools))
  (register-tool!
   (make-tool :name 'harness-describe-tool
              :description "Return the description, permission, and schema of a registered tool by name."
              :permission  :read
              :schema      '((:name :type :string :required-p t
                              :description "Tool name as shown by harness-list-tools."))
              :handler     #'%tool-describe-tool))
  (register-tool!
   (make-tool :name 'harness-list-hooks
              :description "List the registered hook keys and how many handlers each has."
              :permission  :read
              :schema      ()
              :handler     #'%tool-list-hooks))
  (register-tool!
   (make-tool :name 'harness-version
              :description "Return the harness version string (e.g. \"0.1.0\")."
              :permission  :read
              :schema      ()
              :handler     #'%tool-version))
  (register-tool!
   (make-tool :name 'harness-now
              :description "Return the current UTC time in ISO-8601 format."
              :permission  :read
              :schema      ()
              :handler     #'%tool-now)))

(defparameter *builtin-tool-names*
  '(harness-list-tools harness-describe-tool harness-list-hooks
    harness-version harness-now)
  "Names of all built-in tools. Convenience for agents that want them all:
  (make-instance 'agent ... :tools *builtin-tool-names*).")

;; Auto-register on file load.
(install-builtin-tools!)
