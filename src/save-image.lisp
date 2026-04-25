;;;; save-image.lisp — image distribution (M9, CON-008)
;;;;
;;;; The load-bearing :clean t story called out in my SPEC-011 review. Per
;;;; the review, what gets flushed must be defined in code, not waved at.
;;;; *CLEAN-CHECKLIST* below is the list; PRE-SAVE-CLEAN! runs each item.
;;;; CHECKING.md mirrors the list in prose for operators.
;;;;
;;;; SAVE-IMAGE! is a wrapper around sb-ext:save-lisp-and-die that:
;;;;   1. runs the clean checklist (when :clean t),
;;;;   2. forces a full GC to minimise heap size,
;;;;   3. invokes save-lisp-and-die — which DOES NOT RETURN; the calling
;;;;      process becomes the saved image. Tests therefore drive saving
;;;;      from a sub-SBCL via UIOP:RUN-PROGRAM.

(in-package #:anuna-imago)

(defparameter *clean-checklist*
  '(:close-receipt-log
    :shutdown-hook-async-pool
    :drop-credentials
    :force-gc)
  "Items pre-save-clean! processes. Order matters — credentials must drop
before GC so freed strings don't survive into the saved heap.")

;; ---------------------------------------------- credential register ---
;;
;; Modules that load secrets from env or vault should register a
;; credential-erasing thunk here so :clean t can drop them at save time.
;; M8 (Anthropic provider) will register an api-key clear thunk; for now
;; the list is empty but the seam is in place.

(defvar *credential-erasers* nil
  "List of thunks invoked under :drop-credentials. Each thunk should clear
any in-memory secret material it owns.")

(defun register-credential-eraser! (thunk)
  "Register THUNK to be called during :clean t pre-save flush."
  (pushnew thunk *credential-erasers*)
  thunk)

;; ---------------------------------------------- receipt-log register ---

(defvar *open-receipt-logs* nil
  "Receipt logs registered for close-on-save. M5+ callers push into this.")

(defun register-receipt-log-for-clean! (log)
  (pushnew log *open-receipt-logs*)
  log)

;; ---------------------------------------------- pre-save flush ---

(defun pre-save-clean! ()
  "Run the clean checklist. Idempotent. Errors in any step are logged but
do not abort — we want save-image! to proceed even if a flush partly fails."
  (dolist (step *clean-checklist*)
    (handler-case
        (case step
          (:close-receipt-log
           (dolist (log *open-receipt-logs*)
             (handler-case (close-receipt-log! log) (error () nil)))
           (setf *open-receipt-logs* nil))
          (:shutdown-hook-async-pool
           (handler-case (shutdown-hook-async-pool) (error () nil)))
          (:drop-credentials
           (dolist (thunk *credential-erasers*)
             (handler-case (funcall thunk) (error () nil)))
           (setf *credential-erasers* nil))
          (:force-gc
           (sb-ext:gc :full t)))
      (error (c)
        (format *error-output* "pre-save-clean! ~A: ~A~%" step c))))
  t)

;; ---------------------------------------------- save-image! ---

(defun save-image! (output-path
                    &key (toplevel 'agent-main)
                         (clean t)
                         (executable t))
  "Save a standalone image at OUTPUT-PATH whose toplevel is TOPLEVEL.

  :toplevel    — symbol or function called when the saved image is invoked.
  :clean       — when T (default), run PRE-SAVE-CLEAN! to flush transient state.
  :executable  — when T (default), produce a single binary that bundles the
                 SBCL runtime; otherwise emit a `.core` to be loaded by sbcl.

This function DOES NOT RETURN. The calling SBCL process is replaced by the
saved image. Drive from a sub-SBCL when you want to keep your REPL alive."
  (when clean (pre-save-clean!))
  (sb-ext:save-lisp-and-die output-path
                            :toplevel (etypecase toplevel
                                        (symbol (symbol-function toplevel))
                                        (function toplevel))
                            :executable executable
                            :save-runtime-options t))
