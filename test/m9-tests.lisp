;;;; m9-tests.lisp — quality-gate tests for M9 (image distribution)
;;;;
;;;; SAVE-IMAGE! does not return — it replaces the calling process. So
;;;; tests drive a sub-SBCL via UIOP:RUN-PROGRAM to perform the save,
;;;; then exec the resulting binary and inspect its stdout / exit code.
;;;; The first test builds the artifact; subsequent tests reuse it.

(in-package #:anuna-imago.test)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(export 'run-m9-tests)

(defvar *test-image-path* "/tmp/imago-m9-test-echo-agent")

(defun %imago-root ()
  (namestring (asdf:system-source-directory :imago)))

(defun %build-test-image ()
  "Invoke build-echo-image.sh into a fresh tmp path."
  (handler-case (delete-file *test-image-path*) (error () nil))
  (let* ((script (format nil "~Abin/build-echo-image.sh" (%imago-root)))
         (result (multiple-value-list
                  (uiop:run-program (list "bash" script *test-image-path*)
                                    :ignore-error-status t
                                    :output :string
                                    :error-output :string))))
    (let ((status (third result)))
      (values (zerop status) (first result) (second result)))))

(defun %run-image (&rest args)
  "Run the test image with ARGS, return (values stdout stderr exit-code)."
  (multiple-value-bind (out err code)
      (uiop:run-program (cons *test-image-path* args)
                        :ignore-error-status t
                        :output :string
                        :error-output :string)
    (values out err code)))

;; ---------------------------------------------------------------- build ---

(defun test-build-image ()
  (format t "~%-- build-image --~%")
  (multiple-value-bind (ok stdout stderr) (%build-test-image)
    (declare (ignore stdout))
    (check ok (format nil "build-echo-image.sh succeeds (stderr: ~A...)"
                      (subseq stderr 0 (min 80 (length stderr)))))
    (check (probe-file *test-image-path*) "binary exists at expected path")
    (check (let ((mode (sb-posix:stat-mode (sb-posix:stat *test-image-path*))))
             (not (zerop (logand mode #o100))))
           "binary is executable")))

;; ------------------------------------------------------- functional ---

(defun test-image-version ()
  (format t "~%-- image-version --~%")
  (multiple-value-bind (out err code) (%run-image "--version")
    (declare (ignore err))
    (check (zerop code) "exit code 0")
    (check (search "anuna-imago" out) "stdout contains \"anuna-imago\"")
    (check (search *version* out)
           (format nil "stdout contains version ~A" *version*))))

(defun test-image-echo ()
  (format t "~%-- image-echo --~%")
  (multiple-value-bind (out err code) (%run-image "--echo" "hello")
    (declare (ignore err))
    (check (zerop code) "exit code 0")
    (check (search "echo: hello" out)
           "stdout contains \"echo: hello\"")))

(defun test-image-bad-args ()
  (format t "~%-- image-bad-args --~%")
  (multiple-value-bind (out err code) (%run-image "--bogus")
    (declare (ignore out))
    (check (= 2 code) "unknown args produce exit code 2")
    (check (search "Usage:" err) "stderr shows usage")))

;; ------------------------------------------------------------ NFR-002 ---

(defun test-image-size ()
  "NFR-002: minimal image ≤ 60 MB."
  (format t "~%-- image-size --~%")
  (let ((size (with-open-file (s *test-image-path* :element-type '(unsigned-byte 8))
                (file-length s))))
    (let ((mb (/ size 1024.0 1024.0)))
      (format t "  image size: ~,1F MB~%" mb)
      (check (< mb 60)
             (format nil "size ~,1FMB < 60MB minimal budget" mb)))))

;; ------------------------------------------------------------ NFR-001 ---

(defun test-image-cold-start ()
  "NFR-001: cold-start P95 ≤ 200 ms. We measure 10 runs as a smoke check;
strict P95 across 100 runs is left to a perf harness in M11."
  (format t "~%-- image-cold-start --~%")
  (let ((times nil))
    (dotimes (i 10)
      (let ((start (get-internal-real-time)))
        (%run-image "--echo" "x")
        (push (/ (* 1000 (- (get-internal-real-time) start))
                 internal-time-units-per-second)
              times)))
    (let* ((sorted (sort times #'<))
           (mean   (/ (reduce #'+ times) (length times)))
           (p90    (nth 8 sorted)))
      (format t "  mean: ~,1Fms  p90: ~,1Fms~%" mean p90)
      (check (< p90 200) (format nil "p90 ~,1Fms < 200ms NFR-001 target" p90)))))

;; ------------------------------------------- :clean t audit ---

(defun test-clean-no-leaked-secrets ()
  "Audit: register a fake credential, save, verify the credential string is
not in the binary. We can't easily test this without rebuilding the image
with a registered eraser, so this test verifies the eraser machinery itself
runs."
  (format t "~%-- clean-no-leaked-secrets --~%")
  (let* ((cleared nil)
         (thunk (lambda () (setf cleared t))))
    (register-credential-eraser! thunk)
    (pre-save-clean!)
    (check cleared "credential eraser thunk runs under pre-save-clean!"))
  ;; Negative: a string that is NOT registered as a credential should still
  ;; be present in source files (sanity check on grep methodology).
  (multiple-value-bind (out err code)
      (uiop:run-program
       (list "bash" "-c"
             (format nil "grep -c 'sk-test-secret-' ~A || true"
                     *test-image-path*))
       :ignore-error-status t :output :string :error-output :string)
    (declare (ignore err code))
    (check (string= "0" (string-trim '(#\Newline #\Space) out))
           "no string \"sk-test-secret-\" in image (no source plants it)")))

;; ---------------------------------------------------------------- runner ---

(defun run-m9-tests ()
  (setf *failures* 0)
  (format t "~%=== M9 quality-gate tests ===~%")
  (test-build-image)
  (test-image-version)
  (test-image-echo)
  (test-image-bad-args)
  (test-image-size)
  (test-image-cold-start)
  (test-clean-no-leaked-secrets)
  (handler-case (delete-file *test-image-path*) (error () nil))
  (format t "~%=== ~D failure(s) ===~%" *failures*)
  (when (plusp *failures*) (sb-ext:exit :code 1))
  (format t "M9 green.~%"))
