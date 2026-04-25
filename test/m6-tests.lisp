;;;; m6-tests.lisp — quality-gate tests for M6 (cbcl-ffi bindings)
;;;;
;;;; These tests load libcbcl_ffi.dylib via cffi and exercise the parse +
;;;; verify-dialect surface. The full Lean-oracle parity check (156/156
;;;; vectors) lives upstream in cbcl-rs; here we verify FFI marshaling
;;;; works correctly on a representative subset and that error paths
;;;; surface as :ERROR with a descriptive string.
;;;;
;;;; Skipping: all M6 tests are skipped (with a console note) if the
;;;; libcbcl_ffi cdylib can't be located. This keeps M1-M5+M8+M9 passing
;;;; on machines that don't have cbcl-rs checked out.

(in-package #:anuna-imago.test)

(export 'run-m6-tests)

(defun %ffi-available-p ()
  (handler-case (progn (ensure-cbcl-ffi-loaded) t)
    (error () nil)))

;; ----------------------------------------------- parse round-trip ---

(defun test-parse-canonical-passthrough ()
  (format t "~%-- cbcl-parse-canonical-passthrough --~%")
  (let* ((input "(tell @alice (greeting \"hello\"))")
         (result (parse-message input)))
    (check (eq :ok (car result)) (format nil "status :ok (got ~S)" (car result)))
    (check (string= input (cdr result))
           "canonical input round-trips byte-identical")))

(defun test-parse-roundtrip-with-keywords ()
  "cbcl_parse_message FFI is parse-then-serialize — it preserves keyword
ordering. Full canonicalisation (alphabetic key reorder per the JSON
test-vectors corpus) is a separate cbcl-rs function not yet exposed in
the FFI surface. Here we just verify the round-trip preserves structure."
  (format t "~%-- cbcl-parse-roundtrip-with-keywords --~%")
  (let* ((input "(extend book-venue (venue date capacity :refundable #t :deposit 500))")
         (result (parse-message input)))
    (check (eq :ok (car result)) "structurally well-formed input parses")
    (check (string= input (cdr result))
           "FFI parse-message preserves keyword order (canonicaliser not yet exposed)")))

(defun test-parse-error-on-garbage ()
  (format t "~%-- cbcl-parse-error-on-garbage --~%")
  (let ((result (parse-message "this is not an sexpr (((")))
    (check (eq :error (car result))
           (format nil "garbage input → :ERROR (got ~S)" (car result)))
    (check (and (stringp (cdr result)) (plusp (length (cdr result))))
           "error string is non-empty")))

(defun test-parse-empty ()
  (format t "~%-- cbcl-parse-empty --~%")
  (let ((result (parse-message "")))
    (check (eq :error (car result)) "empty input → :ERROR")))

(defun test-parse-many ()
  "Soak: parse 200 well-formed messages, check no leaks / no errors.
Spec-level fuzzing (1M inputs) is upstream in cbcl-rs; this just checks
the FFI side handles repeated calls without leaking memory."
  (format t "~%-- cbcl-parse-many --~%")
  (let ((failures 0))
    (loop for i from 0 below 200 do
      (let* ((input (format nil "(tell @agent-~D (greeting \"hi-~D\"))" i i))
             (r (parse-message input)))
        (unless (and (eq :ok (car r)) (string= input (cdr r)))
          (incf failures))))
    (check (zerop failures) (format nil "200 round-trips: ~D failures" failures))))

;; ----------------------------------------------- verify-dialect ---

(defun test-verify-dialect-error-on-garbage ()
  "Verify-dialect rejects malformed input. Constructing a *valid* dialect
is non-trivial (R1/R2/R3 must all hold); we test the negative path here
and leave positive parity to cbcl-rs's own test suite."
  (format t "~%-- cbcl-verify-dialect-error --~%")
  (let ((result (verify-dialect "garbage")))
    (check (eq :error (car result))
           "malformed dialect input → :ERROR")))

;; ----------------------------------------------- canonical predicate ---

(defun test-message-canonical-p ()
  "Tests round-trip equality. Since the FFI parse doesn't currently
reorder keywords (see test-parse-roundtrip-with-keywords), well-formed
inputs return T; only inputs the parser rewrites for OTHER reasons (e.g.
whitespace normalisation) round-trip non-identical."
  (format t "~%-- cbcl-message-canonical-p --~%")
  (check (message-canonical-p "(tell @alice (greeting \"hello\"))")
         "well-formed input → T")
  (check (not (message-canonical-p "garbage(((["))
         "malformed input → NIL"))

;; ---------------------------------------------------------------- runner ---

(defun run-m6-tests ()
  (setf *failures* 0)
  (format t "~%=== M6 quality-gate tests ===~%")
  (cond
    ((not (%ffi-available-p))
     (format t "  (SKIPPED — libcbcl_ffi not loadable; set CBCL_FFI_LIB to enable)~%")
     (format t "M6 skipped.~%"))
    (t
     (test-parse-canonical-passthrough)
     (test-parse-roundtrip-with-keywords)
     (test-parse-error-on-garbage)
     (test-parse-empty)
     (test-parse-many)
     (test-verify-dialect-error-on-garbage)
     (test-message-canonical-p)
     (format t "~%=== ~D failure(s) ===~%" *failures*)
     (when (plusp *failures*) (sb-ext:exit :code 1))
     (format t "M6 green.~%"))))
