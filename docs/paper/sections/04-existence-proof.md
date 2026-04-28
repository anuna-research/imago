# §4. anuna-imago as existence proof

We have built a runtime that follows the three principles, called
**anuna-imago**. The implementation is approximately 4100 lines of Common
Lisp on SBCL with a further 3340 lines of tests; the harness is small enough
to read in an afternoon, and small enough that no part of it is load-bearing
in the sense that the user cannot replace it. We offer the artifact as a
demonstration that the principles cohere into a working system, not as a
product pitch — the choice of substrate (SBCL Common Lisp) carries real
costs that we acknowledge explicitly below.

## A worked redefinition

The headline behaviour of the runtime is that any method can be redefined at
the live REPL and the redefinition will survive an image save. The following
~10 lines of transcript construct an agent against a stub provider, ask it,
redefine the provider's `stream!` method to produce different output, ask
again (new behaviour, same process, no restart), then save the heap as an
executable binary. Running the binary from the shell produces output
consistent with the redefined method:

```lisp
(defparameter *agent* (build-echo-agent))
(spawn-agent! *sup* *agent*)
(getf (ask-agent *agent* "hi") :text)               ; => "echo: hi"

(defmethod provider-stream! ((p stub-provider) agent message)
  (declare (ignore agent))
  (let* ((c (if (listp message) (getf message :content) message))
         (cell (cons nil (list (list :text (format nil "shouted: ~A!"
                                                   (string-upcase c)))))))
    (lambda () (pop (cdr cell)))))

(getf (ask-agent *agent* "hi") :text)               ; => "shouted: HI!"

(save-image! "shouty-agent" :toplevel 'agent-main)
```

```sh
$ ./shouty-agent --echo "hello"
shouted: HELLO!
```

No framework migration ticket; no rebuild step. The patch survives because
the binary *is* the heap.

## Safety from invariants in practice

The SPEC-012 self-modification port instantiates Principle 3. A
`harness-eval` tool lets the agent submit Common Lisp source forms for
evaluation; before evaluation, three layers gate the call: a pre-filter
denylist for obvious structural violations, a defeasible-logic reasoner
querying a Spindle theory of floor invariants, and a handler that runs the
form under timeout with a rollback register for any methods it redefines.
A published log of six goal-driven runs with GLM 5.1 records the agent
self-redefining 18 symbols across 6 turns to add persistent memory to
itself, with 3 vetoes from the floor invariants intercepting attempts to
redefine the safety surface. The invariants are short, queryable, and
authored once.

## Honest costs

Common Lisp on SBCL is a small ecosystem with a sharp learning curve and
genuine hiring difficulty. Teams committed to Python or TypeScript ergonomics
will not adopt anuna-imago verbatim. Our argument is structural: *some*
substrate that supports these principles must exist, and substrates that do
not — including the typical Python-based agent stack — pay back the
limitation as migration cost over time. anuna-imago demonstrates that the
position is realisable; it does not claim to be the realisation everyone
should choose.
