;;;; examples/echo.lisp — reference echo agent
;;;;
;;;; The minimal viable Phase-1 agent: receives an ask, replies "echo: <X>".
;;;; Demonstrates the supervisor + agent + turn-loop + stub-provider stack
;;;; without any networking. Once gateway (M7) lands, swap stub-provider
;;;; for an Anthropic provider and the same agent talks to the real router.

(in-package #:anuna-imago)

(defun build-echo-agent (&key (id 'echo-agent) (capability "echo:say"))
  "Build (but do not start) an echo agent."
  (make-instance 'agent
                 :id id
                 :capability capability
                 :provider (make-stub-provider)
                 :system-prompt "You are echo. Repeat the user's message."))

(defun run-echo-demo ()
  "Standalone demo: spawn an echo agent, ask it three things, drain.
Returns a list of replies received."
  (let* ((sup   (make-supervisor 'echo-sup :max-restarts 3))
         (agent (build-echo-agent)))
    (spawn-agent! sup agent)
    (sleep 0.05)                            ; let the loop start
    (let ((replies (list (ask-agent agent "hello")
                         (ask-agent agent "world")
                         (ask-agent agent "!"))))
      ;; Tell the agent's loop to exit, then drain.
      (send! (agent-mailbox agent) :shutdown)
      (sleep 0.05)
      (drain-supervisor! sup)
      (mapcar (lambda (r) (getf r :text)) replies))))
