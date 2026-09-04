;;;; reasoner.lisp — Spindle reasoner integration via IPC (M10, CON-006)
;;;;
;;;; The reasoner is the Stance-defining seam: per SPEC-011 §"Stance",
;;;; defeasible logic is used ONLY as an invariant filter at :on-tool-call.
;;;; It is NOT a turn-loop reasoning augmentor — capability-augmenting
;;;; use is excluded by Stance and not exposed in this module's API.
;;;;
;;;; IPC indirection: *REASONER-IPC-CALL* is the seam tests inject a mock
;;;; through. Production points it at a Unix-socket or HTTP client to
;;;; spindle-rs; tests bind it to a function returning canned proof-results.
;;;;
;;;; A proof-result is a plist:
;;;;   (:tag <:+delta | :+partial-delta | :-delta | :-partial-delta>
;;;;    :derivation <list-or-nil>
;;;;    :time-ms <integer>)
;;;; matching SPEC-011 CON-006 prose.

(in-package #:anuna-imago)

;; ---------------------------------------------------- IPC indirection ---

(defvar *reasoner-ipc-call*
  (lambda (op &rest args)
    (declare (ignore op args))
    (error "Reasoner IPC not configured. Bind *REASONER-IPC-CALL* to a stub or production endpoint."))
  "Function (OP &REST ARGS) → result. OP is one of :LOAD-THEORY,
:QUERY, :WHAT-IF, :WHY-NOT, :ASSERT-FACT, :RETRACT-FACT.")

;; ---------------------------------------------------- public API ---

(defun load-theory (text-or-path)
  "Return an opaque theory handle. PATH or literal theory text accepted."
  (funcall *reasoner-ipc-call* :load-theory text-or-path))

(defun query (handle goal)
  "Evaluate GOAL against HANDLE. Returns a proof-result plist:
  (:tag :+delta | :+partial-delta | :-delta | :-partial-delta
   :derivation ... :time-ms N)."
  (funcall *reasoner-ipc-call* :query handle goal))

(defun what-if (handle goal facts)
  "Hypothetical: query GOAL given the union of HANDLE's theory and FACTS.
Theory is unmodified."
  (funcall *reasoner-ipc-call* :what-if handle goal facts))

(defun why-not (handle goal)
  "Counter-derivation: explain why GOAL is not provable."
  (funcall *reasoner-ipc-call* :why-not handle goal))

(defun assert-fact! (handle fact)
  (funcall *reasoner-ipc-call* :assert-fact handle fact))

(defun retract-fact! (handle fact)
  (funcall *reasoner-ipc-call* :retract-fact handle fact))

;; ---------------------------------------------------- invariant filter ---

(defun %proper-list-p (object)
  "Recognize a finite proper list, rejecting atoms, dotted tails, and cycles."
  (loop with slow = object
        with fast = object
        do (cond
             ((null fast) (return t))
             ((atom fast) (return nil))
             ((null (cdr fast)) (return t))
             ((atom (cdr fast)) (return nil)))
           (setf slow (cdr slow)
                 fast (cddr fast))
           (when (eq slow fast) (return nil))))

(defparameter *active-theory-handle* nil
  "Theory handle the default invariant filter consults at :on-tool-call.
SET via INSTALL-INVARIANT-FILTER!; cleared by PRE-SAVE-CLEAN! through
the credential-eraser registry so the handle does not leak into images.")

(defun %proof-result-valid-p (result)
  "Recognize the exact proof-result grammar before a guarded side effect."
  (handler-case
      (and (%proper-list-p result)
           (= 6 (length result))
           (let ((keys (loop for tail on result by #'cddr
                             collect (first tail))))
             (and (every (lambda (key)
                           (member key '(:tag :derivation :time-ms)))
                         keys)
                  (= 1 (count :tag keys))
                  (= 1 (count :derivation keys))
                  (= 1 (count :time-ms keys))
                  (member (getf result :tag)
                          '(:+delta :+partial-delta :-delta :-partial-delta))
                  (%proper-list-p (getf result :derivation))
                  (let ((time-ms (getf result :time-ms)))
                    (and (integerp time-ms) (not (minusp time-ms)))))))
    (error () nil)))

(defun proof-result-positive-p (result)
  "T if RESULT carries a positive tag (+Δ or +∂) — i.e., the reasoner
concluded the goal IS provable."
  (and (%proof-result-valid-p result)
       (member (getf result :tag) '(:+delta :+partial-delta))))

(defun invariant-filter-hook (agent call)
  "Sync-transformative hook for :on-tool-call. Asks the active theory
whether the call is FORBIDDEN; if the reasoner answers yes (+Δ or +∂),
returns :VETO. Only a valid negative proof permits the call."
  (declare (ignore agent))
  (cond
    ((null *active-theory-handle*) :veto)
    (t
     (let* ((tool-name (getf call :name))
            (args      (getf call :args))
            (goal      (list :forbidden tool-name args))
            (result    (handler-case (query *active-theory-handle* goal)
                         (error () nil))))
       (cond
         ((not (%proof-result-valid-p result)) :veto)
         ((proof-result-positive-p result) :veto)
         (t call))))))

(defvar *invariant-filter-handle* nil
  "Hook handle returned by INSTALL-INVARIANT-FILTER!. Kept so an operator
can REMOVE-HOOK to disable filtering without restart.")

(defun install-invariant-filter! (&key theory-handle)
  "Install the invariant filter on :on-tool-call. THEORY-HANDLE binds
*ACTIVE-THEORY-HANDLE* atomically with the install — cleaner than two
mutations from caller code. Returns the hook handle."
  (when theory-handle
    (setf *active-theory-handle* theory-handle))
  (setf *invariant-filter-handle*
        (register-hook :on-tool-call #'invariant-filter-hook))
  ;; Wire :clean t to drop the theory handle so it doesn't ride into images.
  (register-credential-eraser!
   (lambda () (setf *active-theory-handle* nil)))
  *invariant-filter-handle*)

(defun uninstall-invariant-filter! ()
  "Remove the filter (live; no restart needed)."
  (when *invariant-filter-handle*
    (remove-hook *invariant-filter-handle*)
    (setf *invariant-filter-handle* nil)))
