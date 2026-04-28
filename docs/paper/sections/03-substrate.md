# §3. The amputable substrate

We use *amputable substrate* to name a runtime in which every layer is
removable, replaceable, or redefinable in flight. The framework provides
infrastructure for the choices that don't depend on model capability; the
user provides the choices that do. Three principles make the term concrete.

## Principle 1: every layer redefinable at runtime without restart

The framework treats methods as dispatch points, not call sites. Tool
selection, hook handling, provider streaming, prompt assembly — each is a
named operation whose implementation can be replaced while the system runs.
The lineage runs through McCarthy's metacircular `eval` [McCarthy 1960]
and its descendants in Lisp and Smalltalk: the language can interpret and
modify its own representation. When a built-in in the framework turns out
to encode an obsolete assumption, the user redefines it at the live REPL
instead of filing a framework migration ticket. The framework cannot bake
"the right way to do X" into a closed implementation; instead it exposes
the seam where X is dispatched and offers a default. This is more demanding
than configurability — configuration assumes the framework anticipated the
axes of variation. Late binding does not.

## Principle 2: the runtime artifact is the heap

Distribution is image distribution. The deployed binary is a frozen heap,
including any patches the user applied at the live REPL before the snapshot
was taken. There is no separate deployment pipeline whose assumptions might
themselves age out — there is no pipeline, only the heap. A consequence is
that the redefined-in-flight semantics survives deployment: the binary
behaves exactly as the running image did at the moment of save. SBCL's
`save-lisp-and-die` produces a single-file executable in this style
[Steele & Gabriel 1996], descended from the Lisp-Machine and Smalltalk
image traditions [Goldberg & Robson 1983]. The implication for framework
design is that any tool the framework offers must be safe to freeze
mid-flight: open files, credentials, network handles must either be cleaned
before save or tolerate restoration on resume.

## Principle 3: safety from invariants, not pipelines

Safety is not a sequence of checks the framework runs in a fixed order; it
is a set of statements about the system that must always hold. The framework
gates on whether invariants are violated, but does not own the invariants
themselves. The user authors them — in this implementation, in defeasible
logic — and the framework consults them at the relevant points. The
practical consequence is that when the model gains a new capability, the
invariants don't need to change. A pipeline-based safety story, by contrast,
gets longer with every new capability surface: a new tool means a new
validator, a new orchestration step, a new place to forget a check. An
invariant-based story stays the same size: the new capability either does
or does not violate the existing rules. anuna-imago's SPEC-012
self-modification port queries a Spindle defeasible-logic theory at every
`harness-eval` call; the theory is the entire safety contract for that
surface, and the framework's role is reduced to "ask the reasoner, veto on
positive verdict."
