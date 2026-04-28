# §1. Introduction

**Title.** *Modular, self-evolving agent runtimes.*

## Abstract

Most LLM-agent frameworks today embed assumptions about what models can or
cannot do — planner modules, prompt-template engines, output parsers,
hand-written tool-dispatch logic. Such assumptions age badly under Sutton's
bitter lesson: as model capability climbs, scaffolding becomes obsolete and
the framework's value collapses into migration burden. We argue that agent
runtimes should commit to *operational scaffolding only* — supervision,
identity, audit, capability routing — and treat every other layer as an
part of a *modular, self-evolving runtime* — one the user can redefine in
flight, and one the agent itself can extend under safety gates. Three principles
follow: every layer redefinable at runtime without restart, the runtime
artifact is the heap, and safety comes from invariants, not pipelines. We
offer **anuna-imago**, a ~4100-LOC SBCL Common Lisp harness, as an existence
proof. We acknowledge the wager openly: if model capability plateaus, the
prescriptive frameworks were correct to bake in scaffolding.

## Introduction

What should an LLM-agent runtime commit to? The mainstream answer over the
past three years has been to give the developer a planner, a memory module,
a tool selector, a prompt-template engine, and a curated dispatch loop. These
abstractions answer the question *"what does the model need help doing?"* —
and in answering it, they commit the framework to a specific theory of
contemporary model limitation. The thesis of this paper is that such commitments
are wagers against capability scaling, and they have been losing.

Concrete examples — without naming particular projects, since the structural
argument is independent of any one of them — are easy to find. Frameworks that
shipped explicit planner modules in 2022 found that 2023's chain-of-thought
tool-use loops did the same work in less code. Frameworks that shipped regex
or grammar-based output parsers in 2023 found that 2024's structured-output
modes obsoleted them in months. Frameworks that built elaborate prompt-template
engines for fragile instruction-following found that the templating value
shrank as instruction-following improved. In every case the framework's
abstractions encoded a model limitation, the limitation lifted, and the
abstraction became dead weight or migration debt.

The alternative we propose is to refuse, at the framework layer, to encode
assumptions about model capability. Commit only to *operational scaffolding* —
supervision, identity, audit, capability routing, image distribution, runtime
safety invariants. These are about how the agent process *exists and is
governed*, not about what work it does. They are stable across model
generations because they are not predictions about model behaviour at all.

This stance has consequences. Three principles structure them: every layer
must be redefinable at runtime without restart (the user must be able to
amputate framework decisions in flight), the runtime artifact must be the
heap (so live redefinitions survive deployment), and safety must come from
invariants rather than from prescriptive pipelines (so the safety contract
does not need to extend each time the model gains a capability). The remainder
of this paper develops these principles (§3), connects them to the bitter
lesson (§2), offers anuna-imago as a concrete existence proof (§4), positions
the stance against adjacent traditions (§5), and concludes by acknowledging
the wager (§6).
