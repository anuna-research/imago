# anuna-imago

A small, hackable agent runtime for SBCL Common Lisp. You build your agent
at the REPL, save it as a single binary with `save-lisp-and-die`, and ship
it. While it's running you can attach SLIME and redefine any function —
the turn loop, a tool handler, the supervisor itself — without restarting.

The runtime is supervised processes. The wire is CBCL. The substrate is
fully redefinable in flight. Roughly 2200 lines of Common Lisp.

## Why this shape?

Agent frameworks tend to embed assumptions about what models *can't* do —
planning modules, prompt-pipeline curation, output parsers — and those
assumptions age badly as model capability climbs. anuna-imago commits to
**operational scaffolding only**: supervision, identity, audit, capability
routing, image distribution, runtime safety invariants. If a layer turns
out to encode an obsolete assumption, you redefine it at the live REPL
instead of filing a framework migration ticket.

This is the working implementation of [SPEC-011][spec], constrained to
~2000 LOC. See the spec for the full argument; the README assumes you just
want to run it.

[spec]: https://codeberg.org/anuna/anuna-code/src/branch/main/spec/SPEC-011-image-harness.md

## Setup

You need SBCL 2.6+, Quicklisp, and (optionally, for the CBCL parser tests)
a local checkout of [`cbcl-rs`][cbcl-rs] with its FFI cdylib built.

[cbcl-rs]: https://codeberg.org/anuna/cbcl-rs

```bash
# 1. SBCL
brew install sbcl                                    # macOS
# or:    sudo apt-get install sbcl libffi-dev        # Debian/Ubuntu

# 2. Quicklisp (one-time)
curl -O https://beta.quicklisp.org/quicklisp.lisp
sbcl --no-userinit --no-sysinit --load quicklisp.lisp \
     --eval '(quicklisp-quickstart:install)' --quit

# 3. (Optional) cbcl-rs cdylib for the M6 FFI tests
git clone https://codeberg.org/anuna/cbcl-rs ../cbcl-rs
( cd ../cbcl-rs && cargo build --release -p cbcl-ffi )
```

That's the lot. anuna-imago itself is loaded via ASDF from this directory
— no install step, no path-mangling.

## Try it

```bash
bash bin/run-tests.sh all          # 11 milestone test suites, ~30s
bash bin/build-echo-image.sh       # produces ./echo-agent (~37 MB)

./echo-agent --version
# anuna-imago 0.1.0

./echo-agent --echo "hello world"
# echo: hello world

echo "ping" | ./echo-agent --serve
# echo: ping
# [drain on EOF]

./echo-agent --serve 60            # serve for 60s, drain on SIGTERM/SIGINT
```

The echo agent uses a stub provider — no API key required. Swap in the
real Anthropic provider and you get a working LLM-backed agent in another
~10 lines of customisation (next section).

## Mental model

A running agent is **one OS process** holding an SBCL image. Inside it:

```
┌──────────────────────────────────────────────────────────┐
│  agent process                                           │
│                                                          │
│  ┌────────────┐                                          │
│  │ supervisor │  one-for-one restart policy              │
│  └─────┬──────┘                                          │
│        │ spawns / monitors                               │
│        ▼                                                 │
│  ┌────────────┐    ┌────────────┐    ┌─────────────┐     │
│  │  worker    │    │  worker    │    │  gateway    │     │
│  │  (agent +  │    │  (agent +  │    │  (CBCL      │     │
│  │  turn-loop)│    │  turn-loop)│    │   router)   │     │
│  └─────┬──────┘    └────────────┘    └──────┬──────┘     │
│        │ inbox                              │            │
│        ▼                                    ▼            │
│  ┌────────────┐                       ┌──────────────┐   │
│  │  mailbox   │◄──── ask / reply ────►│  WebSocket   │   │
│  └────────────┘                       └──────────────┘   │
└──────────────────────────────────────────────────────────┘
```

The **turn loop** is the heart of it. For each inbound ask:

```
agent          turn-loop          hook chain          tool registry
  │ ask           │                   │                   │
  ├──────────────►│ provider-stream!  │                   │
  │               ├──── HTTP ─────►   │                   │
  │               │◄── tool_use ──    │                   │
  │               │ run-hook          │                   │
  │               │  :on-tool-call    │                   │
  │               ├──────────────────►│ Spindle reasoner: │
  │               │                   │ (forbidden …) ?   │
  │               │◄──────────────────┤ -∂ → pass         │
  │               │ dispatch-tool!    │                   │
  │               ├──────────────────────────────────────►│
  │               │◄── result ────────────────────────────┤
  │ reply         │                                       │
  │◄──────────────┤ :tool-results                         │
```

Five seams to know about:

- **Methods** are `defmethod` — redefine at the REPL, the next call uses
  the new version.
- **Hooks** at `:on-user-input`, `:on-tool-call`, `:on-tool-result`,
  `:on-turn-complete`, `:on-agent-spawn`, `:on-agent-crash`. Sync hooks
  thread a value through the chain; first to return `:veto` aborts.
- **Providers** are CLOS classes implementing `provider-stream!`. Stubs
  for tests, Anthropic in production; Bedrock/Vertex are drop-in.
- **Transports** are abstract — production uses `wss-transport` (a wrapper
  around `websocket-driver`) to talk to a CBCL router; tests use an
  in-memory `mock-transport` plus a Clack-hosted echo server for round-trip.
- **Reasoner** integration is IPC-only. At `:on-tool-call` the harness
  asks a Spindle defeasible-logic theory whether the call is `(forbidden …)`;
  a +Δ or +∂ verdict vetoes before the tool ever runs.

## Built-in tools

Five small tools auto-register when `imago` loads. They cover
introspection on the harness itself — useful both for an agent that
wants to discover its own surface and for a human debugging a deployed
binary. Agents that don't list them in `:tools` don't expose them to
the LLM, so registration is harmless.

| Name | Returns |
|---|---|
| `harness-list-tools` | List of all registered tool names |
| `harness-describe-tool` | `{description, permission, schema}` for a named tool |
| `harness-list-hooks` | Hook keys + handler counts |
| `harness-version` | Harness version string |
| `harness-now` | Current UTC time, ISO-8601 |

```lisp
;; Wire all of them into an agent:
(make-instance 'agent ... :tools *builtin-tool-names*)
```

What's deliberately **not** built in: file IO, shell exec, HTTP fetch,
web search. Those are exactly the "agent framework" abstractions
SPEC-011's bitter-lesson stance refused — they age badly as model
capability climbs, and they're better-served by MCP servers or per-
project tool modules. Two opt-in trapdoors (`harness-eval` and
`harness-redefine-method`) for self-modification live in
`examples/self-modifying.lisp` (planned, not in this branch) so the
author has to consciously enable them.

## Build your own agent

Three things to customise: tools, system prompt, provider.

```lisp
;; my-agent.lisp
(in-package #:anuna-imago)

;; 1. Define tools the LLM can call.
(define-tool current-time
  :description "Return the current ISO-8601 UTC timestamp."
  :schema      ()
  :handler     (lambda (args) (declare (ignore args)) (iso-8601-now)))

(define-tool greet
  :description "Greet someone by name."
  :schema      ((:name :type :string :required-p t :description "Person to greet"))
  :handler     (lambda (args) (format nil "Hello, ~A." (getf args :name))))

;; 2. Wire an agent that uses them, against a real provider.
(defun my-toplevel ()
  (let* ((provider (make-anthropic-provider))    ; reads ANTHROPIC_API_KEY
         (sup      (make-supervisor 'my-sup))
         (agent    (make-instance 'agent
                                  :id            'clock
                                  :capability    "time:lookup"
                                  :provider      provider
                                  :system-prompt "You are a clock agent."
                                  :tools         '(current-time greet))))
    (spawn-agent! sup agent)
    (sleep 0.05)
    (let ((reply (ask-agent agent "What time is it? Greet Hugo while you're at it.")))
      (format t "~%~A~%" (getf reply :text))
      (dolist (r (getf reply :tool-results))
        (format t "  [~A] → ~A~%" (getf r :name) (getf r :value))))
    (send! (agent-mailbox agent) :shutdown)
    (drain-supervisor! sup)))
```

Save it as a binary:

```bash
sbcl --no-userinit --no-sysinit \
     --load ~/quicklisp/setup.lisp \
     --eval "(push (truename \".\") asdf:*central-registry*)" \
     --eval "(asdf:load-system :imago)" \
     --eval "(load \"my-agent.lisp\")" \
     --eval "(anuna-imago:save-image! \"my-agent\"
                                       :toplevel 'anuna-imago::my-toplevel
                                       :executable t)"

ANTHROPIC_API_KEY=sk-… ./my-agent
```

`./my-agent` is now a self-contained 56 MB binary you can `scp` to any
machine that doesn't have SBCL installed. `:clean t` (default) flushes
credentials, async pools, and open log handles before the save — see
[`architecture/CHECKING.md`](./architecture/CHECKING.md) for the full
audit checklist.

To make the agent reachable from a CBCL router, build a `gateway` over a
`wss-transport`:

```lisp
(let* ((tr (make-wss-transport "wss://router.example/agent/v1"
                                :headers '(("authorization" . "Bearer …"))))
       (gw (make-gateway :id 'my-gw
                         :transport tr
                         :identity "agent-token"
                         :capability "echo:say"
                         :agent agent)))
  (gateway-connect! gw)
  (gateway-start-pumps! gw))
```

`test/m7-tests.lisp` shows the full lifecycle against a mock router;
`test/m7-wss-tests.lisp` exercises the same surface against a real
WebSocket round-trip on loopback.

## Project layout

```
anuna-imago/
├── bin/
│   ├── build-echo-image.sh           save-lisp-and-die wrapper
│   └── run-tests.sh                  test runner
├── src/
│   ├── packages.lisp                 package definitions
│   ├── main.lisp                     agent-main entry + --serve loop
│   │
│   ├── mailbox.lisp                  ┐
│   ├── supervisor.lisp               │  supervised actor primitives
│   ├── agent.lisp                    ┘
│   │
│   ├── hooks.lisp                    hook registry, sync + fire-and-forget
│   ├── tools.lisp                    define-tool, JSON Schema as CL data
│   ├── builtin-tools.lisp            harness-{list,describe,now,version,…}
│   ├── turn-loop.lisp                default per-message loop
│   │
│   ├── receipt-log.lisp              content-addressed audit log
│   ├── save-image.lisp               save-image! + :clean checklist
│   │
│   ├── gateway.lisp                  CBCL router client (transport-abstract)
│   ├── wss-transport.lisp            websocket-driver-backed transport
│   ├── cbcl-ffi.lisp                 CBCL parser via FFI to cbcl-rs
│   ├── reasoner.lisp                 Spindle IPC + invariant filter
│   │
│   └── providers/
│       ├── stub.lisp                 canned-response provider for tests
│       └── anthropic.lisp            Messages API + mockable HTTP
│
├── test/                             one suite per milestone (M1–M11)
├── examples/echo.lisp                reference echo agent
├── architecture/
│   ├── ADR-001-image-runtime.md      why SBCL (not ECL)
│   └── CHECKING.md                   :clean t audit checklist
├── plan.spl                          implementation plan (hence)
└── .github/workflows/ci.yml          matrix CI + LOC-budget gate
```

## Status & known gaps

v0.1 — all 12 implementation milestones plus the production WebSocket
transport are merged; 13 test suites, 200+ checks, all green.

Two things are scoped-down compared to a full production deployment:

- **Provider streaming.** The Anthropic provider uses the non-streaming
  Messages API. Streaming SSE — and the stateful tool-call accumulation
  it needs — is a future enhancement.
- **CI matrix.** GitHub Actions runs M1–M5, M7-WSS, M8–M11 on macOS +
  Ubuntu. M6 (the cbcl-rs FFI tests) is gated off until the CI prelude
  grows a cbcl-rs cdylib build step.

By the numbers: 2424 LOC harness, ~2100 LOC tests, 57 MB image with WSS
transport in heap, 175 ms p90 cold start.

## Where to dig next

- [`SPEC-011`][spec] — the original specification this is an implementation of
- [`architecture/ADR-001-image-runtime.md`](./architecture/ADR-001-image-runtime.md) — why SBCL specifically
- [`architecture/CHECKING.md`](./architecture/CHECKING.md) — what `:clean t` actually does at save time
- [`plan.spl`](./plan.spl) — implementation plan as defeasible-logic rules; query with `hence plan board plan.spl`
- [`test/m4-tests.lisp`](./test/m4-tests.lisp) — the most readable end-to-end exercise of the runtime
- [`test/m7-tests.lisp`](./test/m7-tests.lisp) — gateway round-trip against the mock router

## License

Apache-2.0 — see [LICENSE](./LICENSE).
