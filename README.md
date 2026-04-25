# anuna-imago

Minimal hackable agent harness on SBCL Common Lisp.

The 2k-LOC variant of [SPEC-011](https://codeberg.org/anuna/anuna-code/src/branch/main/spec/SPEC-011-image-harness.md): the agent is an SBCL image, the runtime is supervised processes, the wire is CBCL, the substrate is fully redefinable in flight.

## Status

**v0.1 reference implementation** — all 12 milestones from [`plan.spl`](./plan.spl) are merged. Run `hence plan board plan.spl` to see the board (12 done, 0 pending). All 11 milestone test suites are green; CI matrix at `.github/workflows/ci.yml`.

| Number      | Value                                                 |
| ----------- | ----------------------------------------------------- |
| Harness LOC | 2199 (target was ~2000)                               |
| Tests LOC   | 1854                                                  |
| Image size  | 37 MB minimal / 56 MB with provider+jzon              |
| Cold start  | 175 ms p90                                            |
| Append log  | 0.008 ms mean per receipt                             |
| Suites      | 11 milestones × 200+ quality-gate checks, all green   |

## What this is

- **Image-as-artifact**: agents ship as standalone SBCL binaries via `save-lisp-and-die`.
- **Operational scaffolding only**: supervision, identity, audit, distribution, runtime safety invariants. Capability augmentation is declined per the SPEC-011 bitter-lesson stance and **enforced in code** — `register-hook :on-prompt-build` errors at runtime.
- **Hackable in flight**: every function — turn loops, hooks, tools, supervision, providers — is redefinable at the live REPL via SLIME/SLY without restart. Tested under a running supervisor (`m4-tests test-process-turn-redefinable`).
- **Contracts at every external seam**: CBCL router (CON-001), CBCL messages (CON-002, FFI to `cbcl-rs`), hooks (CON-003), tools (CON-004), provider drivers (CON-005), reasoner (CON-006), image format (CON-008). Each has an indirection seam (`*ANTHROPIC-HTTP-POST*`, `*REASONER-IPC-CALL*`, `MOCK-TRANSPORT`) so tests don't need live external services.

## What this isn't (per the 2k cut)

- Not multi-cloud — Anthropic only in v0.1 (CON-005 contract preserved for Bedrock / Vertex drivers later).
- Not self-improving — optimization primitives (`fork-agent`, `replay-corpus`, `score`, `promote-image!`) deferred. The Stance was already skeptical of them; an out-of-tree add-on can return them later if justified.
- Not multi-strategy supervised — only `:one-for-one` ships. Other OTP strategies deferred.
- Not an in-CL CBCL parser — FFI to [`cbcl-rs`](https://codeberg.org/anuna/cbcl-rs) (resolves SPEC-011 open-Q-2). Inherits its Lean-verified oracle parity for free.
- Not streaming — Anthropic provider uses non-streaming Messages API in v0.1; SSE deferred.

## Quick start

```bash
# Requires SBCL 2.6+, Quicklisp installed at ~/quicklisp.
# (Quicklisp install: curl https://beta.quicklisp.org/quicklisp.lisp |
#                     sbcl --no-sysinit --no-userinit --load /dev/stdin \
#                          --eval '(quicklisp-quickstart:install)' --quit)

bash bin/run-tests.sh all              # 11 suites; takes ~30s
bash bin/build-echo-image.sh           # produces ./echo-agent (37 MB)

./echo-agent --version                 # anuna-imago 0.1.0
./echo-agent --echo "hello world"      # echo: hello world
echo "hi" | ./echo-agent --serve       # stdin-driven; drains on EOF
./echo-agent --serve 60                # serve for 60s, then drain
```

For development, attach SLIME to a running image and redefine any function in flight — `defmethod` bodies, hooks, the turn loop itself.

## How a tool call flows

```
agent          turn-loop          hook chain          registry
  │ ask           │                   │                   │
  ├──────────────►│ provider-stream!  │                   │
  │               ├──── HTTP ─────►   │                   │
  │               │◄── tool_use ──    │                   │
  │               │ run-hook          │                   │
  │               │  :on-tool-call    │                   │
  │               ├──────────────────►│ Spindle:          │
  │               │                   │ (forbidden …) ?   │
  │               │◄──────────────────┤ -∂ → pass         │
  │               │ dispatch-tool!    │                   │
  │               ├──────────────────────────────────────►│
  │               │◄── result ────────────────────────────┤
  │ reply         │                                       │
  │◄──────────────┤ :tool-results                         │
```

## Project layout

```
anuna-imago/
├── imago.asd                   ASDF system definition
├── plan.spl                    Hence implementation plan (12 milestones)
├── README.md                   you are here
├── LICENSE                     Apache-2.0
├── .github/workflows/ci.yml    matrix CI + LOC-budget gate
├── architecture/
│   ├── ADR-001-image-runtime.md
│   └── CHECKING.md             :clean t checklist (operator audit)
├── bin/
│   ├── build-echo-image.sh     save-lisp-and-die wrapper
│   └── run-tests.sh            test runner with Quicklisp bootstrap
├── src/
│   ├── packages.lisp           anuna-imago package
│   ├── main.lisp               agent-main entry point + --serve loop
│   ├── mailbox.lisp            sb-thread queue (M1)
│   ├── supervisor.lisp         OTP-style :one-for-one (M1)
│   ├── agent.lisp              CLOS class + lifecycle generics (M1)
│   ├── hooks.lisp              registry + sync/fire-and-forget + stance (M2)
│   ├── tools.lisp              define-tool + JSON Schema as CL data (M3)
│   ├── turn-loop.lisp          provider-streaming loop + frame dispatch (M4)
│   ├── receipt-log.lisp        append-only, content-addressed (M5)
│   ├── cbcl-ffi.lisp           cffi bindings to libcbcl_ffi.dylib (M6)
│   ├── gateway.lisp            CBCL Router Client + transport seam (M7)
│   ├── providers/
│   │   ├── stub.lisp           canned-response provider (M4)
│   │   └── anthropic.lisp      Messages API + mockable HTTP (M8)
│   ├── save-image.lisp         save-image! + :clean checklist (M9)
│   └── reasoner.lisp           Spindle IPC + invariant filter (M10)
├── examples/
│   └── echo.lisp
└── test/
    └── m{1..11}-tests.lisp     one suite per milestone
```

## Resolved SPEC-011 open questions

- **Q1 (SBCL vs ECL)** → SBCL. See `architecture/ADR-001-image-runtime.md`.
- **Q2 (CBCL parser strategy)** → FFI to cbcl-rs. See `src/cbcl-ffi.lisp`.
- **Q3 (Reasoner placement)** → IPC only (in-process FFI dropped per 2k cut). See `src/reasoner.lisp`.
- **Q4 (`:clean t` checklist)** → defined in code (`*clean-checklist*` in `src/save-image.lisp`) and prose (`architecture/CHECKING.md`).
- **Q5 (Receipt log durability)** → append-only file, no sqlite (per 2k cut). See `src/receipt-log.lisp`.
- **Q6 (Secret distribution)** → modules register credential erasers; `:clean t` flushes before save. See `register-credential-eraser!` in `src/save-image.lisp`.
- **Q7 (Hook deprecation discipline)** → not opt-in. `:on-prompt-build` and `:on-stream-token` error at registration. See `*EXCLUDED-HOOK-KEYS*` in `src/hooks.lisp`.

## Known gaps

- **M7 transport** — only `MOCK-TRANSPORT` is exercised in tests. A real `websocket-driver`-backed transport is a small wrapper around the same defgeneric protocol; left as a follow-up commit.
- **M8 streaming** — non-streaming Messages API only. SSE consumption with stateful tool-call accumulation is a future enhancement.
- **M11 CI matrix** — workflow is in place; the M6 step is gated off until the cbcl-rs cdylib build is added to the matrix prelude.

## License

Apache-2.0 — see [LICENSE](./LICENSE).
