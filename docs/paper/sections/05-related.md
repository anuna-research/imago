# §5. Related stances

The position has antecedents and convergent neighbours.

**The Lisp / Smalltalk image lineage** [McCarthy 1960; Goldberg & Robson
1983]. The substrate spirit we adopt — `eval`/`apply` self-reference, late
binding, image-as-artifact — is the inheritance of fifty years of
metacircular language design. The lineage applied these properties to
*integrated development*: Lisp Machines and Smalltalk-80 were workstations
where the developer and the program lived in the same heap. Our claim is
that the spirit transfers to LLM-agent runtimes, and that the bitter
lesson makes the transfer newly important — not because agent runtimes
are a new application domain, but because they are the first application
domain where the *user of the runtime* (the LLM) has capability that climbs
faster than the framework's release cycle.

**Anthropic's "Building Effective Agents"** [Anthropic 2024]. Recent
engineering writing argues empirically that simpler agent loops — plain
tool-use, no orchestration framework — often outperform complex
multi-agent architectures. We arrive at a convergent stance via a
different argument: the bitter lesson predicts that the orchestration
abstractions will pay obsolescence cost over time. Both directions point
at the same practical conclusion. The convergence between an empirical
engineering finding and a structural theoretical prediction is itself
evidence that the position is robust.

**The Erlang/OTP supervision tradition** [Armstrong 2003]. anuna-imago's
`make-supervisor` is a direct CLOS port of Armstrong's one-for-one
supervisor, and its mailbox abstraction follows the same letterbox-with-pid
shape as Erlang processes. The contribution we claim is *not* the
supervisor — Armstrong's design is fully borrowed and unmodified. The
contribution is to limit framework scope to such established prior art and
push every other concern to user code. Operational scaffolding is not a
new research problem; what is new is committing to it as the *only*
framework concern.
