;;;; m3-tests.lisp — quality-gate tests for M3 (tool registry + schemas)

(in-package #:anuna-imago.test)

(export 'run-m3-tests)

;; ----------------------------------------------- registration & lookup ---

(defun test-define-and-find ()
  (format t "~%-- define-and-find --~%")
  (clear-all-tools)
  (define-tool get-weather
    :description "Get current weather."
    :permission :read
    :schema ((:location :type :string :required-p t :description "City name"))
    :handler (lambda (args)
               (format nil "~A: sunny" (getf args :location))))
  (let ((t1 (find-tool 'get-weather)))
    (check (not (null t1)))
    (check (eq 'get-weather (tool-name t1)))
    (check (string= "Get current weather." (tool-description t1)))
    (check (eq :read (tool-permission t1)))))

(defun test-dispatch ()
  (format t "~%-- dispatch --~%")
  (clear-all-tools)
  (define-tool greet
    :description "Greet someone."
    :schema ((:name :type :string :required-p t))
    :handler (lambda (args)
               (format nil "Hello, ~A" (getf args :name))))
  (check (string= "Hello, World"
                  (dispatch-tool! 'greet (list :name "World")))))

(defun test-redefinable ()
  "REQ-004 substrate: re-defining a tool replaces its handler atomically."
  (format t "~%-- redefinable --~%")
  (clear-all-tools)
  (define-tool counter
    :schema ()
    :handler (lambda (args) (declare (ignore args)) :one))
  (check (eq :one (dispatch-tool! 'counter nil)))
  (define-tool counter
    :schema ()
    :handler (lambda (args) (declare (ignore args)) :two))
  (check (eq :two (dispatch-tool! 'counter nil))
         "next dispatch sees re-defined handler"))

(defun test-unregister ()
  (format t "~%-- unregister --~%")
  (clear-all-tools)
  (define-tool tmp :schema () :handler (lambda (a) (declare (ignore a)) nil))
  (check (not (null (find-tool 'tmp))))
  (check (unregister-tool! 'tmp))
  (check (null (find-tool 'tmp)))
  (check (null (unregister-tool! 'tmp)) "second unregister returns NIL"))

;; --------------------------------------------------- validation ---

(defun test-invalid-permission-errors ()
  (format t "~%-- invalid-permission-errors --~%")
  (clear-all-tools)
  (check (handler-case
             (progn
               (define-tool bad :permission :nope :schema ()
                 :handler (lambda (a) (declare (ignore a)) nil))
               nil)
           (error () t))
         "invalid permission errors at register time"))

(defun test-invalid-type-errors ()
  (format t "~%-- invalid-type-errors --~%")
  (clear-all-tools)
  (check (handler-case
             (progn
               (define-tool bad
                 :schema ((:x :type :weird))
                 :handler (lambda (a) (declare (ignore a)) nil))
               nil)
           (error () t))
         "invalid param type errors at register time"))

;; --------------------------------------------------- schema conversion ---

(defun test-schema-to-json-shape ()
  (format t "~%-- schema-to-json-shape --~%")
  (let* ((schema '((:location :type :string :required-p t :description "City")
                   (:zip :type :string :required-p nil)))
         (j (schema->json-schema schema)))
    (check (string= "object" (cdr (assoc :type j))))
    (let ((props (cdr (assoc :properties j))))
      (check (= 2 (length props)))
      (let ((loc (cdr (assoc "location" props :test #'string=))))
        (check (string= "string" (cdr (assoc :type loc))))
        (check (string= "City" (cdr (assoc :description loc))))))
    (let ((req (cdr (assoc :required j))))
      (check (equal '("location") req)
             "only required-p t params end up in :required"))))

(defun test-schema-roundtrip ()
  (format t "~%-- schema-roundtrip --~%")
  (let* ((original '((:location :type :string :required-p t :description "City")
                     (:zip :type :string :required-p nil :description "Zip")
                     (:age :type :integer :required-p nil)))
         (json (schema->json-schema original))
         (back (json-schema->schema json)))
    ;; Schema entries should equal original (modulo ordering of plist keys).
    (check (= (length original) (length back)))
    (dolist (orig-entry original)
      (let* ((param-name (first orig-entry))
             (back-entry (find param-name back :key #'first)))
        (check (not (null back-entry))
               (format nil "~A round-trips" param-name))
        (check (eq (getf (rest orig-entry) :type)
                   (getf (rest back-entry) :type))
               (format nil "~A type round-trips" param-name))
        (check (eq (or (getf (rest orig-entry) :required-p) nil)
                   (or (getf (rest back-entry) :required-p) nil))
               (format nil "~A required-p round-trips" param-name))
        (check (equal (getf (rest orig-entry) :description)
                      (getf (rest back-entry) :description))
               (format nil "~A description round-trips" param-name))))))

(defun test-anthropic-descriptor ()
  (format t "~%-- anthropic-descriptor --~%")
  (clear-all-tools)
  (define-tool foo
    :description "Foo tool."
    :schema ((:x :type :string :required-p t))
    :handler (lambda (a) (declare (ignore a)) nil))
  (let* ((tool (find-tool 'foo))
         (desc (tool->anthropic-descriptor tool)))
    (check (string= "foo" (cdr (assoc :name desc))))
    (check (string= "Foo tool." (cdr (assoc :description desc))))
    (let ((schema (cdr (assoc :input_schema desc))))
      (check (string= "object" (cdr (assoc :type schema))))
      (check (equal '("x") (cdr (assoc :required schema)))))))

;; ---------------------------------------------------------------- runner ---

(defun run-m3-tests ()
  (setf *failures* 0)
  (format t "~%=== M3 quality-gate tests ===~%")
  (test-define-and-find)
  (test-dispatch)
  (test-redefinable)
  (test-unregister)
  (test-invalid-permission-errors)
  (test-invalid-type-errors)
  (test-schema-to-json-shape)
  (test-schema-roundtrip)
  (test-anthropic-descriptor)
  (format t "~%=== ~D failure(s) ===~%" *failures*)
  (when (plusp *failures*) (sb-ext:exit :code 1))
  (format t "M3 green.~%"))
