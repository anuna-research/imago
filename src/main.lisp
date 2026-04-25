;;;; main.lisp — agent-main entry point (M9 active form)
;;;;
;;;; The toplevel called when a saved image boots (CON-008). v0.1 supports
;;;; two modes:
;;;;
;;;;   ./echo-agent                 → print version and exit
;;;;   ./echo-agent --echo "hello"  → spawn an echo agent under a supervisor,
;;;;                                  send one ask, print the reply, drain.
;;;;
;;;; Once M7 lands, --router URL will replace --echo as the production mode:
;;;; the saved image will connect to a CBCL router and serve indefinitely.

(in-package #:anuna-imago)

(defparameter *version* "0.1.0"
  "anuna-imago version. Bumped on release.")

(defun %build-default-echo-agent ()
  "Build the agent that ./echo-agent --echo uses. Inlined here (rather
than reusing examples/echo.lisp) so the system can be loaded without the
examples module."
  (make-instance 'agent
                 :id 'echo
                 :capability "echo:say"
                 :provider (make-stub-provider)
                 :system-prompt "You are echo. Repeat the user's message."))

(defun %run-echo (msg)
  "Run one echo turn under a supervised agent and return the reply text."
  (let* ((sup   (make-supervisor 'main-sup :max-restarts 3))
         (agent (%build-default-echo-agent)))
    (spawn-agent! sup agent)
    (sleep 0.05)
    (let ((reply (ask-agent agent msg :timeout 5)))
      (send! (agent-mailbox agent) :shutdown)
      (sleep 0.05)
      (drain-supervisor! sup)
      (or (and (listp reply) (getf reply :text))
          ""))))

(defun agent-main ()
  "Toplevel for the saved image."
  (let ((argv (rest sb-ext:*posix-argv*)))
    (cond
      ((null argv)
       (format t "anuna-imago ~A~%" *version*)
       (sb-ext:exit :code 0))
      ((and (string= (first argv) "--echo")
            (second argv))
       (let ((reply-text (%run-echo (second argv))))
         (format t "~A~%" reply-text)
         (sb-ext:exit :code 0)))
      ((string= (first argv) "--version")
       (format t "anuna-imago ~A~%" *version*)
       (sb-ext:exit :code 0))
      (t
       (format *error-output*
               "Usage: ~A [--version | --echo MSG]~%"
               (or (first sb-ext:*posix-argv*) "agent"))
       (sb-ext:exit :code 2)))))
