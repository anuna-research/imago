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
  (let ((p (make-openrouter-provider :model "z-ai/glm-4.6")))
    (sb-posix:setenv "OPENROUTER_API_KEY" "env-key" 1)
    (unwind-protect
         (let ((h (auth-headers p)))
           (check (string= "Bearer env-key"
                           (cdr (assoc "Authorization" h :test #'string=)))))
      (sb-posix:unsetenv "OPENROUTER_API_KEY"))))

(defun test-openrouter-auth-missing-key ()
  (format t "~%-- openrouter-auth-missing-key --~%")
  (sb-posix:unsetenv "OPENROUTER_API_KEY")
  (let ((p (make-openrouter-provider :model "z-ai/glm-4.6")))
    (check (handler-case (progn (auth-headers p) nil)
             (error () t))
           "auth-headers signals when no key + no env")))

;; ------------------------------------------------- response parsing ---

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
    (let ((f1 (funcall stream-fn))
          (f2 (funcall stream-fn))
          (f3 (funcall stream-fn)))
      (check (and (consp f1) (eq :text (first f1))
                  (string= "hello back" (second f1))))
      (check (eq :done f2))
      (check (null f3) "stream drained"))))

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
    (let ((f1 (funcall stream-fn))
          (f2 (funcall stream-fn)))
      (check (and (consp f1) (eq :tool-use (first f1))))
      (check (string= "call_1" (second f1)))
      (check (eq :harness-version (third f1)))
      (check (eq t (getf (fourth f1) :verbose))
             "JSON-string arguments parsed back to a plist")
      (check (eq :done f2)))))

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
    (test-openrouter-response-error-envelope)
    (test-openrouter-http-error-becomes-frame)
    (test-openrouter-credential-eraser)
    (cond ((zerop *failures*)
           (format t "~%~%PASS — openrouter provider tests~%")
           t)
          (t
           (format t "~%~%FAIL — ~D failures in openrouter tests~%" *failures*)
           nil))))
