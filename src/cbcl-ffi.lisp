;;;; cbcl-ffi.lisp — cffi bindings to cbcl-rs's cbcl-ffi cdylib (M6, CON-002)
;;;;
;;;; Resolves SPEC-011 open-Q-2: 2k cut commits to FFI rather than an in-CL
;;;; CBCL parser, so we inherit the Lean-derived oracle parity (156/156)
;;;; and the fuzz coverage (1M random inputs) for free.
;;;;
;;;; Library lookup order (first match wins):
;;;;   1. *CBCL-FFI-LIBRARY-PATH* (special var)
;;;;   2. CBCL_FFI_LIB env var
;;;;   3. ../cbcl-rs/target/release/libcbcl_ffi.dylib  (dev co-checkout)
;;;;   4. ../cbcl-rs/target/release/libcbcl_ffi.so     (Linux dev)
;;;;   5. cffi's default search path (DYLD_LIBRARY_PATH, LD_LIBRARY_PATH, ...)
;;;;
;;;; The Rust FFI surface (from crates/cbcl-ffi/src/lib.rs):
;;;;   cbcl_parse_message  *const c_char  →  CbclResult
;;;;   cbcl_verify_dialect *const c_char  →  CbclResult
;;;;   cbcl_string_free    *mut c_char    →  void
;;;;
;;;; CbclResult = { data: *mut c_char, error: i32 }.
;;;; The owner of `data` is the caller — must be freed with cbcl_string_free
;;;; after consumption. We do that automatically inside %unwrap-result.

(in-package #:anuna-imago)

(defparameter *cbcl-ffi-library-path* nil
  "Explicit path override for libcbcl_ffi. NIL = use search order.")

(defun %resolve-cbcl-ffi-path ()
  "Search the candidate locations for libcbcl_ffi. Returns a path or NIL
to defer to cffi's default loader."
  (or *cbcl-ffi-library-path*
      (uiop:getenv "CBCL_FFI_LIB")
      (probe-file "/Users/anuna-02/Code/cbcl-rs/target/release/libcbcl_ffi.dylib")
      (probe-file "../cbcl-rs/target/release/libcbcl_ffi.dylib")
      (probe-file "../cbcl-rs/target/release/libcbcl_ffi.so")))

(cffi:define-foreign-library cbcl-ffi
  (:darwin (:default "libcbcl_ffi"))
  (:unix   (:default "libcbcl_ffi"))
  (t       (:default "libcbcl_ffi")))

(defvar *cbcl-ffi-loaded* nil)

(defun ensure-cbcl-ffi-loaded ()
  "Idempotently load libcbcl_ffi. Errors with a helpful message if the
library can't be located."
  (unless *cbcl-ffi-loaded*
    (let ((resolved (%resolve-cbcl-ffi-path)))
      (cond
        (resolved
         (cffi:load-foreign-library resolved))
        (t
         (handler-case (cffi:load-foreign-library 'cbcl-ffi)
           (error (c)
             (error "Couldn't find libcbcl_ffi.{dylib,so}.~%~
                    Set *CBCL-FFI-LIBRARY-PATH* or CBCL_FFI_LIB.~%~
                    Original error: ~A" c))))))
    (setf *cbcl-ffi-loaded* t)))

;; ---------------------------------------------------- struct + functions ---

(cffi:defcstruct cbcl-result
  (data  :pointer)
  (error :int))

(cffi:defcfun ("cbcl_parse_message" %cbcl-parse-message) (:struct cbcl-result)
  (input :string))

(cffi:defcfun ("cbcl_verify_dialect" %cbcl-verify-dialect) (:struct cbcl-result)
  (input :string))

(cffi:defcfun ("cbcl_string_free" %cbcl-string-free) :void
  (s :pointer))

;; ---------------------------------------------------- result unwrap ---

(defun %unwrap-result (result)
  "Convert a CbclResult value into either (:OK STRING) or (:ERROR STRING).
Frees the underlying C string before returning.

cffi-libffi returns struct-by-value as a plist with symbols matching the
struct slots: (DATA <pointer> ERROR <int>). We extract via GETF using the
slot symbols from the cbcl-result defcstruct."
  (let* ((data (getf result 'data))
         (err  (getf result 'error)))
    (cond
      ((or (null data) (cffi:null-pointer-p data))
       (cons (if (zerop err) :ok :error) ""))
      (t
       (let ((s (cffi:foreign-string-to-lisp data)))
         (%cbcl-string-free data)
         (cons (if (zerop err) :ok :error) s))))))

;; ---------------------------------------------------- public API ---

(defun parse-message (sexpr-string)
  "Parse a CBCL S-expression string. Returns (:OK CANONICAL-STRING) or
(:ERROR MESSAGE). Round-trips through cbcl-rs's parser/serializer pair
so the OK string is the canonical form (keys sorted, etc.)."
  (ensure-cbcl-ffi-loaded)
  (%unwrap-result (%cbcl-parse-message sexpr-string)))

(defun verify-dialect (dialect-sexpr-string)
  "Parse and verify a dialect definition against R1/R2/R3. Returns
(:OK ...) on success; (:ERROR MESSAGE) describing which rule failed
(or general parse error) on failure."
  (ensure-cbcl-ffi-loaded)
  (%unwrap-result (%cbcl-verify-dialect dialect-sexpr-string)))

;; ---------------------------------------------------- predicates ---

(defun message-canonical-p (sexpr-string)
  "T iff SEXPR-STRING is already in canonical form (parser round-trips it
unchanged). Useful for fast-path checks before re-canonicalising."
  (multiple-value-bind (status val)
      (let ((r (parse-message sexpr-string)))
        (values (car r) (cdr r)))
    (and (eq status :ok) (string= val sexpr-string))))
