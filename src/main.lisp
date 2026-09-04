;;;; main.lisp — agent-main entry point (M11 release form)
;;;;
;;;; The toplevel called when a saved image boots (CON-008). v0.1 modes:
;;;;
;;;;   ./echo-agent                  → print version and exit
;;;;   ./echo-agent --version        → print version and exit
;;;;   ./echo-agent --echo "msg"     → run one echo turn and print the reply
;;;;   ./echo-agent --serve [N]      → run a stdin-driven echo loop. Each
;;;;                                    line is one ask; reply is printed.
;;;;                                    Exits cleanly on SIGTERM/SIGINT or
;;;;                                    after N seconds (defaults: forever).
;;;;
;;;; --serve is the integration target for M11's drainable-shutdown smoke.
;;;; Once a real CBCL router is on hand, --router URL replaces --serve as
;;;; the production mode; --serve stays for testing without one.

(in-package #:anuna-imago)

(defparameter *version* "0.1.0"
  "anuna-imago version. Bumped on release.")

(defvar *active-supervisor* nil
  "Set by --serve mode so the SIGTERM handler can drain it.")
(defvar *active-agent* nil)
(defvar *shutdown-requested* nil)

(defun %build-default-echo-agent ()
  (make-instance 'agent
                 :id 'echo
                 :capability "echo:say"
                 :provider (make-stub-provider)
                 :system-prompt "You are echo. Repeat the user's message."))

(defun %run-echo (msg agent-factory)
  "Run one echo turn under a supervised agent and return the reply text."
  (let* ((sup   (make-supervisor 'main-sup :max-restarts 3))
         (agent (funcall agent-factory)))
    (spawn-agent! sup agent)
    (sleep 0.05)
    (let ((reply (ask-agent agent msg :timeout 5)))
      (send! (agent-mailbox agent) :shutdown)
      (sleep 0.05)
      (drain-supervisor! sup)
      (or (and (listp reply) (getf reply :text))
          ""))))

;; ---------------------------------------------------- signal handler ---

(defun %install-shutdown-handler ()
  "Install SIGTERM and SIGINT handlers that flip *SHUTDOWN-REQUESTED*.
The serve loop checks the flag between asks; when set it drains and exits."
  (flet ((handler (signal info ctx)
           (declare (ignore signal info ctx))
           (setf *shutdown-requested* t)))
    (handler-case
        (sb-sys:enable-interrupt sb-unix:sigterm #'handler)
      (error () nil))
    (handler-case
        (sb-sys:enable-interrupt sb-unix:sigint #'handler)
      (error () nil))))

(defun %drain-and-exit (status-keyword)
  "Drain the active supervisor and exit with a status-coded code."
  (when *active-agent*
    (handler-case (send! (agent-mailbox *active-agent*) :shutdown)
      (error () nil))
    (sleep 0.05))
  (when *active-supervisor*
    (handler-case (drain-supervisor! *active-supervisor*)
      (error () nil)))
  (sb-ext:exit :code (case status-keyword
                       (:drained 0)
                       (:forced  1)
                       (t        0))))

;; ------------------------------------------------------ serve mode ---

(defun %run-serve (max-seconds agent-factory)
  "Stdin-driven serve loop. Each line is treated as an ask; reply printed.
Exits cleanly on EOF, SIGTERM, or after MAX-SECONDS (NIL = forever)."
  (%install-shutdown-handler)
  (let* ((sup   (make-supervisor 'serve-sup :max-restarts 3))
         (agent (funcall agent-factory))
         (deadline (when max-seconds
                     (+ (get-universal-time) max-seconds))))
    (setf *active-supervisor* sup)
    (setf *active-agent* agent)
    (spawn-agent! sup agent)
    (sleep 0.05)
    (loop
      (when *shutdown-requested*
        (format *error-output* "[drain on signal]~%")
        (force-output *error-output*)
        (%drain-and-exit :drained))
      (when (and deadline (>= (get-universal-time) deadline))
        (format *error-output* "[drain on deadline]~%")
        (force-output *error-output*)
        (%drain-and-exit :drained))
      ;; READ-CHAR-NO-HANG distinguishes :eof from :no-data. LISTEN doesn't
      ;; — it returns NIL for both, which would spin the loop forever after
      ;; a finite stdin (file or pipe) is fully drained.
      (let* ((peek (read-char-no-hang *standard-input* nil :eof))
             (line (cond
                     ((eq peek :eof) :eof)
                     ((null peek) (sleep 0.05) :no-input)
                     (t (unread-char peek *standard-input*)
                        (handler-case (read-line *standard-input* nil :eof)
                          (end-of-file () :eof))))))
        (cond
          ((eq line :eof)
           (format *error-output* "[drain on EOF]~%")
           (force-output *error-output*)
           (%drain-and-exit :drained))
          ((eq line :no-input))            ; loop again to recheck signal/deadline
          (t
           (let ((reply (ask-agent agent line :timeout 5)))
             (format t "~A~%" (or (and (listp reply) (getf reply :text)) ""))
             (force-output *standard-output*))))))))

;; ------------------------------------------------------ argv parser ---

(defun agent-main (&optional (agent-factory #'%build-default-echo-agent))
  "Toplevel for the saved image. AGENT-FACTORY supplies echo and serve agents."
  (let ((argv (rest sb-ext:*posix-argv*)))
    (cond
      ((null argv)
       (format t "anuna-imago ~A~%" *version*)
       (sb-ext:exit :code 0))
      ((string= (first argv) "--version")
       (format t "anuna-imago ~A~%" *version*)
       (sb-ext:exit :code 0))
      ((and (string= (first argv) "--echo") (second argv))
       (let ((reply-text (%run-echo (second argv) agent-factory)))
         (format t "~A~%" reply-text)
         (sb-ext:exit :code 0)))
      ((string= (first argv) "--serve")
       (let ((seconds (when (second argv)
                        (handler-case (parse-integer (second argv))
                          (error () nil)))))
         (%run-serve seconds agent-factory)))
      (t
       (format *error-output*
               "Usage: ~A [--version | --echo MSG | --serve [SECONDS]]~%"
               (or (first sb-ext:*posix-argv*) "agent"))
       (sb-ext:exit :code 2)))))
