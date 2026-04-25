;;;; providers/stub.lisp — canned-response provider for testing
;;;;
;;;; A stub provider that does not call any LLM. Configurable behaviour via
;;;; a `responder` slot: a function that takes the inbound message and
;;;; returns either a string (echoed as a single :text frame) or a list of
;;;; pre-built frames. M4 uses this to exercise the turn-loop end-to-end
;;;; before M8 brings the real Anthropic driver online.

(in-package #:anuna-imago)

(defclass stub-provider (provider)
  ((responder :initarg :responder
              :accessor stub-responder
              :initform (lambda (msg)
                          (let ((c (if (listp msg) (getf msg :content) msg)))
                            (format nil "echo: ~A" c)))
              :documentation "Function (message) → string | list-of-frames."))
  (:documentation "Canned-response provider for testing."))

(defmethod provider-name ((p stub-provider)) "stub")

(defun make-stub-provider (&key responder)
  (apply #'make-instance 'stub-provider
         (when responder (list :responder responder))))

(defmethod provider-stream! ((p stub-provider) agent message)
  "Build the frame list, then return a closure consuming it."
  (declare (ignore agent))
  (let* ((response (funcall (stub-responder p) message))
         (frames   (cond
                     ((stringp response)
                      (list (list :text response)))
                     ((listp response)
                      response)
                     (t (list (list :text (princ-to-string response)))))))
    ;; A stream is a closure over the frame list; calling it pops one frame.
    (let ((cell (cons nil frames)))         ; sentinel head
      (lambda () (pop (cdr cell))))))

(defmethod stream-next-frame! ((stream function))
  "Streams produced by stub-provider are closures returning the next frame
or NIL. NIL is rendered as :done."
  (or (funcall stream) :done))
