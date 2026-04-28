;;;; plugins/zai/test.lisp — Z.ai Coding Plan plugin tests
;;;;
;;;; Stubbed — no live API key needed.

(in-package #:anuna-imago.test)

(export 'run-zai-tests)

;; ------------------------------------------------- constructor ---

(defun test-zai-make-provider-defaults ()
  (format t "~%-- zai-make-provider-defaults --~%")
  (let ((p (make-zai-coding-provider :api-key "test-key")))
    (check (typep p 'anthropic-provider) "produces an anthropic-provider")
    (check (string= "https://api.z.ai/api/anthropic" (anthropic-base-url p)))
    (check (string= "glm-5.1" (anthropic-model p)))
    (check (string= "test-key" (anthropic-api-key p)))))

(defun test-zai-make-provider-overrides ()
  (format t "~%-- zai-make-provider-overrides --~%")
  (let ((p (make-zai-coding-provider :api-key "k"
                                     :model "glm-4.7"
                                     :base-url "https://example.com/anthropic"
                                     :max-tokens 1024)))
    (check (string= "glm-4.7" (anthropic-model p)))
    (check (string= "https://example.com/anthropic" (anthropic-base-url p)))
    (check (= 1024 (anthropic-max-tokens p)))))

;; ------------------------------------------------- opencode auth.json ---

(defun test-zai-read-opencode-key-roundtrip ()
  (format t "~%-- zai-read-opencode-key-roundtrip --~%")
  ;; Write a fake auth.json then read it back.
  (let ((path (format nil "/tmp/imago-zai-test-auth-~D.json" (random 100000))))
    (with-open-file (s path :direction :output :if-exists :supersede)
      (princ "{\"zai-coding-plan\":{\"type\":\"api\",\"key\":\"key-from-opencode\"},
                \"openrouter\":{\"type\":\"api\",\"key\":\"or-key\"}}"
             s))
    (unwind-protect
         (progn
           (check (string= "key-from-opencode"
                           (read-opencode-zai-key :path path)))
           (check (string= "or-key"
                           (read-opencode-zai-key :path path :slug "openrouter")))
           (check (null (read-opencode-zai-key :path path :slug "missing-slug")))
           (check (null (read-opencode-zai-key :path "/nonexistent.json"))
                  "missing file → NIL, not signal"))
      (handler-case (delete-file path) (error () nil)))))

(defun test-zai-make-provider-with-opencode-slug ()
  (format t "~%-- zai-make-provider-with-opencode-slug --~%")
  (let ((path (format nil "/tmp/imago-zai-opencode-~D.json" (random 100000))))
    (with-open-file (s path :direction :output :if-exists :supersede)
      (princ "{\"zai-coding-plan\":{\"type\":\"api\",\"key\":\"opencode-key\"}}" s))
    (unwind-protect
         (let ((*zai-opencode-auth-path* path))
           (let ((p (make-zai-coding-provider :opencode-slug "zai-coding-plan")))
             (check (string= "opencode-key" (anthropic-api-key p))
                    ":opencode-slug pulls the key from the configured path")))
      (handler-case (delete-file path) (error () nil)))))

(defun test-zai-make-provider-explicit-key-wins ()
  (format t "~%-- zai-make-provider-explicit-key-wins --~%")
  (let ((path (format nil "/tmp/imago-zai-precedence-~D.json" (random 100000))))
    (with-open-file (s path :direction :output :if-exists :supersede)
      (princ "{\"zai-coding-plan\":{\"type\":\"api\",\"key\":\"opencode-key\"}}" s))
    (unwind-protect
         (let ((*zai-opencode-auth-path* path))
           (let ((p (make-zai-coding-provider :api-key "explicit"
                                              :opencode-slug "zai-coding-plan")))
             (check (string= "explicit" (anthropic-api-key p))
                    ":api-key wins over :opencode-slug")))
      (handler-case (delete-file path) (error () nil)))))

;; ------------------------------------------------- end-to-end stubbed ---

(defun test-zai-roundtrip-via-stubbed-anthropic ()
  (format t "~%-- zai-roundtrip-via-stubbed-anthropic --~%")
  ;; The plugin builds an anthropic-provider, so the existing
  ;; *anthropic-http-post* stub seam works. We assert the URL the driver
  ;; tries to hit includes the Z.ai endpoint.
  (let* ((p (make-zai-coding-provider :api-key "k"))
         (a (make-instance 'agent :id 'z :system-prompt nil :tools nil))
         (captured-url nil)
         (canned (com.inuoe.jzon:stringify
                   (anuna-imago::%ht
                    "id" "msg-1"
                    "stop_reason" "end_turn"
                    "content" (vector (anuna-imago::%ht "type" "text"
                                                         "text"  "ok"))))))
    (let ((*anthropic-http-post*
            (lambda (url &key headers content)
              (declare (ignore headers content))
              (setf captured-url url)
              canned)))
      (let ((stream-fn (provider-stream! p a (make-ask "hi"))))
        (let ((f1 (funcall stream-fn))
              (f2 (funcall stream-fn)))
          (check (and (consp f1) (eq :text (first f1)) (string= "ok" (second f1))))
          (check (eq :done f2))
          (check (search "api.z.ai/api/anthropic" captured-url)
                 "request hits the Z.ai endpoint, not api.anthropic.com")
          (check (search "/v1/messages" captured-url)
                 "appends /v1/messages — same path shape as Anthropic"))))))

;; ------------------------------------------------- runner ---

(defun run-zai-tests ()
  (format t "~%========================================~%")
  (format t " Z.ai GLM Coding Plan plugin~%")
  (format t "========================================~%")
  (let ((*failures* 0))
    (test-zai-make-provider-defaults)
    (test-zai-make-provider-overrides)
    (test-zai-read-opencode-key-roundtrip)
    (test-zai-make-provider-with-opencode-slug)
    (test-zai-make-provider-explicit-key-wins)
    (test-zai-roundtrip-via-stubbed-anthropic)
    (cond ((zerop *failures*)
           (format t "~%~%PASS — zai plugin tests~%")
           t)
          (t
           (format t "~%~%FAIL — ~D failures in zai plugin tests~%" *failures*)
           nil))))
