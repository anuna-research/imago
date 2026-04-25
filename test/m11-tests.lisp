;;;; m11-tests.lisp — release smoke for M11
;;;;
;;;; Builds a fresh image, exercises --version / --echo / --serve, runs the
;;;; LOC budget audit, and verifies :clean t didn't leak the test marker.

(in-package #:anuna-imago.test)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-posix))

(export 'run-m11-tests)

(defvar *m11-image-path* "/tmp/imago-m11-release-image")

(defun %imago-root-path ()
  (namestring (asdf:system-source-directory :imago)))

(defun %build-release-image ()
  (handler-case (delete-file *m11-image-path*) (error () nil))
  (let* ((script (format nil "~Abin/build-echo-image.sh" (%imago-root-path))))
    (multiple-value-bind (stdout stderr code)
        (uiop:run-program (list "bash" script *m11-image-path*)
                          :ignore-error-status t
                          :output :string :error-output :string)
      (declare (ignore stdout))
      (values (zerop code) stderr))))

;; --------------------------------------------------- end-to-end smoke ---

(defun test-release-build-and-version ()
  (format t "~%-- release-build-and-version --~%")
  (multiple-value-bind (ok stderr) (%build-release-image)
    (check ok (format nil "release image built (stderr: ~A)"
                      (subseq stderr 0 (min 80 (length stderr)))))
    (multiple-value-bind (out err code)
        (uiop:run-program (list *m11-image-path* "--version")
                          :ignore-error-status t :output :string :error-output :string)
      (declare (ignore err))
      (check (zerop code))
      (check (search *version* out)))))

(defun test-release-echo-multiple ()
  "Multi-call smoke: each invocation should be an independent fresh image
boot, and each should produce the right echo. Exercises NFR-001 cold
start under load."
  (format t "~%-- release-echo-multiple --~%")
  (let ((failures 0))
    (loop for i from 0 below 5 do
      (multiple-value-bind (out err code)
          (uiop:run-program (list *m11-image-path* "--echo"
                                   (format nil "msg-~D" i))
                            :ignore-error-status t :output :string :error-output :string)
        (declare (ignore err))
        (unless (and (zerop code)
                     (search (format nil "echo: msg-~D" i) out))
          (incf failures))))
    (check (zerop failures) (format nil "5 cold-boot echoes: ~D failures" failures))))

;; --------------------------------------------------- drainable shutdown ---

(defun test-release-serve-and-eof ()
  "Pipe lines into --serve via a temp file, close stdin → image drains
on EOF and exits 0. Using a file (rather than a CL string-stream) keeps
stdin a real fd at the OS level, which UIOP/RUN-PROGRAM needs to close
deterministically."
  (format t "~%-- release-serve-and-eof --~%")
  (let ((input-path (format nil "/tmp/imago-m11-stdin-~A" (random 1000000))))
    (unwind-protect
         (progn
           (with-open-file (s input-path :direction :output :if-exists :supersede)
             (write-string (format nil "hello~%world~%") s))
           (multiple-value-bind (out err code)
               (uiop:run-program
                (format nil "~A --serve < ~A" *m11-image-path* input-path)
                :ignore-error-status t
                :output :string :error-output :string)
             (declare (ignore err))
             (check (zerop code) "serve exits 0 on EOF")
             (check (search "echo: hello" out))
             (check (search "echo: world" out))))
      (handler-case (delete-file input-path) (error () nil)))))

(defun test-release-serve-deadline ()
  "Serve mode with a deadline drains itself even with no stdin activity.
We close stdin so LISTEN doesn't block; the deadline path triggers exit."
  (format t "~%-- release-serve-deadline --~%")
  (let ((start (get-internal-real-time)))
    (multiple-value-bind (out err code)
        (uiop:run-program
         (format nil "~A --serve 2 < /dev/null" *m11-image-path*)
         :ignore-error-status t
         :output :string :error-output :string)
      (declare (ignore out err))
      (let ((elapsed-ms (* 1000.0 (/ (- (get-internal-real-time) start)
                                      internal-time-units-per-second))))
        (check (zerop code) "deadline-exit returns 0")
        (check (< elapsed-ms 5000)
               (format nil "deadline-driven exit within ~,1Fms" elapsed-ms))))))

;; --------------------------------------------------- :clean audit ---

(defun test-release-no-secrets-leaked ()
  "Scan the binary for any well-known credential prefixes."
  (format t "~%-- release-no-secrets-leaked --~%")
  (multiple-value-bind (out err code)
      (uiop:run-program
       (list "bash" "-c"
             (format nil
                     "grep -ao -E '(sk-[a-zA-Z0-9]{20,}|Bearer [a-zA-Z0-9]{20,})' ~A | head -5 || true"
                     *m11-image-path*))
       :ignore-error-status t :output :string :error-output :string)
    (declare (ignore err code))
    (check (zerop (length (string-trim '(#\Newline #\Space) out)))
           "no credential-shaped strings found in release image")))

;; --------------------------------------------------- LOC budget ---

(defun %count-loc (path)
  (with-open-file (s path :direction :input :if-does-not-exist nil)
    (if s (loop for line = (read-line s nil nil) while line count 1) 0)))

(defun test-loc-budget ()
  "Acceptance: harness LOC tracked over time. Cap raised to 2700 after
the built-in tier expanded from 5 to 10 tools (~85 LOC of new handlers
+ exports + agent.lisp's *current-agent* binding)."
  (format t "~%-- loc-budget --~%")
  (let* ((root (%imago-root-path))
         (harness-files
           (list "src/agent.lisp" "src/builtin-tools.lisp" "src/cbcl-ffi.lisp"
                 "src/gateway.lisp" "src/hooks.lisp" "src/mailbox.lisp"
                 "src/main.lisp" "src/packages.lisp" "src/reasoner.lisp"
                 "src/receipt-log.lisp" "src/save-image.lisp"
                 "src/supervisor.lisp" "src/tools.lisp" "src/turn-loop.lisp"
                 "src/wss-transport.lisp"
                 "src/providers/stub.lisp" "src/providers/anthropic.lisp"))
         (total (reduce #'+ (mapcar (lambda (f) (%count-loc (concatenate 'string root f)))
                                    harness-files))))
    (format t "  harness LOC: ~D~%" total)
    (check (< total 2700)
           (format nil "harness LOC ~D under 2700" total))))

;; ---------------------------------------------------------------- runner ---

(defun run-m11-tests ()
  (setf *failures* 0)
  (format t "~%=== M11 quality-gate tests ===~%")
  (test-release-build-and-version)
  (test-release-echo-multiple)
  (test-release-serve-and-eof)
  (test-release-serve-deadline)
  (test-release-no-secrets-leaked)
  (test-loc-budget)
  (handler-case (delete-file *m11-image-path*) (error () nil))
  (format t "~%=== ~D failure(s) ===~%" *failures*)
  (when (plusp *failures*) (sb-ext:exit :code 1))
  (format t "M11 green.~%"))
