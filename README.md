# anuna-imago

Minimal hackable agent harness on SBCL Common Lisp.

The 2k-LOC variant of [SPEC-011](https://codeberg.org/anuna/anuna-code/src/branch/main/spec/SPEC-011-image-harness.md): the agent is an SBCL image, the runtime is supervised processes, the wire is CBCL, the substrate is fully redefinable in flight. Total budget ~1830 LOC of harness code plus borrowed infrastructure (bordeaux-threads, dexador, websocket-driver, jzon, cffi, swank).

## Status

`alpha` — under active construction per [`plan.spl`](./plan.spl). Twelve milestones (M0 → M11). Run `hence plan board plan.spl` for the current state.

## What this is

- **Image-as-artifact**: agents ship as SBCL binaries via `save-lisp-and-die`.
- **Operational scaffolding only**: supervision, identity, audit, distribution, runtime safety invariants. Capability augmentation declined per the bitter-lesson stance.
- **Hackable in flight**: every function — turn loops, hooks, tools, supervision, providers — is redefinable at the live REPL via SLIME/SLY without restart.
- **Contracts at every external seam**: CBCL router, providers, reasoner all behind explicit interfaces.

## What this isn't (per the 2k cut)

- Not multi-cloud — Anthropic only in v0.1 (CON-005 contract preserved for later drivers).
- Not self-improving — optimization primitives (fork/replay/score/promote) deferred. Out-of-tree add-on later.
- Not multi-strategy supervised — only `:one-for-one` ships. Other OTP-style strategies deferred.
- Not an in-CL CBCL parser — FFI to [`cbcl-rs`](https://codeberg.org/anuna/cbcl-rs) inherits its Lean-verified oracle parity for free.

## Quick start

Requires SBCL 2.6+ and Quicklisp.

```bash
sbcl --load imago.asd \
     --eval '(asdf:load-system :imago)' \
     --eval '(anuna-imago:agent-main)'
```

For development, attach SLIME to a running image to redefine functions in flight without restart.

## Project layout

```
anuna-imago/
├── imago.asd           ASDF system definition
├── plan.spl            Hence implementation plan
├── README.md
├── LICENSE
├── architecture/       ADRs
├── src/                Harness modules (grows per plan.spl)
├── examples/           Reference agents (echo, calendar, etc.)
└── test/               Test harness (added at M1+)
```

## License

Apache-2.0 — see [LICENSE](./LICENSE).
