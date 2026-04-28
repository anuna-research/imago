# §6. Conclusion

Agent runtimes should commit to operational scaffolding only — supervision,
identity, audit, capability routing — and treat every other layer as an
modular, self-evolving runtime that the user, or the agent itself, can redefine in flight. Three principles
implement the position: live redefinition, image-as-artifact, invariants
not pipelines. anuna-imago, ~4100 LOC of Common Lisp, demonstrates that the
position is realisable. The wager is plain: if model capability plateaus in
the next several years, prescriptive frameworks were correct to bake in
scaffolding and we paid for under-engineering. If capability continues
climbing, prescriptive frameworks pay migration debt forever and the
substrate position wins by attrition. The artifact is at
`codeberg.org/anuna/imago`. Take it apart.
