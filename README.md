<a id="readme-top"></a>

<!-- PROJECT SHIELDS -->
[![Apache 2.0 License][license-shield]][license-url]
[![Status: Experimental][status-shield]][status-url]
[![Common Lisp][cl-shield]][cl-url]
[![SBCL 2.6+][sbcl-shield]][sbcl-url]
[![Tests][tests-shield]][tests-url]
[![LOC][loc-shield]][loc-url]


<!-- PROJECT HEADER -->
<br />
<div align="center">
  <h1 align="center">anuna-imago</h1>

  <p align="center">
    A small, hackable agent runtime for SBCL Common Lisp.
    <br />
    Build your agent at the REPL · save it as a single binary ·
    redefine any function in flight without restart.
    <br />
    <br />
    <a href="#try-it">Try it</a>
    ·
    <a href="#built-in-tools">Built-in tools</a>
    ·
    <a href="#roadmap">Roadmap</a>
    ·
    <a href="https://codeberg.org/anuna/imago/issues">Report a bug</a>
  </p>
</div>


<!-- TABLE OF CONTENTS -->
<details>
  <summary>Table of Contents</summary>
  <ol>
    <li>
      <a href="#about-the-project">About The Project</a>
      <ul>
        <li><a href="#built-with">Built With</a></li>
      </ul>
    </li>
    <li>
      <a href="#getting-started">Getting Started</a>
      <ul>
        <li><a href="#prerequisites">Prerequisites</a></li>
        <li><a href="#installation">Installation</a></li>
      </ul>
    </li>
    <li>
      <a href="#usage">Usage</a>
      <ul>
        <li><a href="#try-it">Try it</a></li>
        <li><a href="#redefine-in-flight">Redefine in flight</a></li>
        <li><a href="#mental-model">Mental model</a></li>
        <li><a href="#built-in-tools">Built-in tools</a></li>
        <li><a href="#harness-evolution-control-plane">Harness evolution control plane</a></li>
        <li><a href="#build-your-own-agent">Build your own agent</a></li>
      </ul>
    </li>
    <li><a href="#project-layout">Project layout</a></li>
    <li><a href="#api-reference">API Reference</a></li>
    <li><a href="#roadmap">Roadmap</a></li>
    <li><a href="#contributing">Contributing</a></li>
    <li><a href="#license">License</a></li>
    <li><a href="#contact">Contact</a></li>
    <li><a href="#acknowledgments">Acknowledgments</a></li>
  </ol>
</details>



<!-- ABOUT THE PROJECT -->
## About The Project

Agent frameworks tend to embed assumptions about what models *can't* do —
planning modules, prompt-pipeline curation, output parsers — and those
assumptions age badly as model capability climbs. **anuna-imago** commits
to operational scaffolding only: supervision, identity, audit, capability
routing, image distribution, runtime safety invariants. If a layer turns
out to encode an obsolete assumption, you redefine it at the live REPL
instead of filing a framework migration ticket.

The core harness is kept behind a soft line budget, while optional subsystems
load separately. The runtime is supervised processes. The wire is CBCL. The
substrate is fully redefinable in flight.

<p align="right">(<a href="#readme-top">back to top</a>)</p>


### Built With

* [![SBCL][sbcl-tile]][sbcl-url]
* [![websocket-driver][wsd-tile]][wsd-url]
* [![dexador][dex-tile]][dex-url]
* [![com.inuoe.jzon][jzon-tile]][jzon-url]
* [![CFFI][cffi-tile]][cffi-url]
* [![ironclad][ironclad-tile]][ironclad-url]
* [![cbcl-rs][cbcl-tile]][cbcl-url]

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- GETTING STARTED -->
## Getting Started

### Prerequisites

* SBCL 2.6+
  ```sh
  brew install sbcl                                    # macOS
  sudo apt-get install sbcl libffi-dev                 # Debian/Ubuntu
  ```
* Quicklisp (one-time)
  ```sh
  curl -O https://beta.quicklisp.org/quicklisp.lisp
  sbcl --no-userinit --no-sysinit --load quicklisp.lisp \
       --eval '(quicklisp-quickstart:install)' --quit
  ```
* Optional, only for the M6 CBCL FFI tests — [`cbcl-rs`][cbcl-url] cdylib
  ```sh
  git clone https://codeberg.org/anuna/cbcl-rs ../cbcl-rs
  ( cd ../cbcl-rs && cargo build --release -p cbcl-ffi )
  ```

### Installation

```sh
# Clone into anuna-imago/ to match the package name and directory tree below.
git clone https://codeberg.org/anuna/imago anuna-imago
cd anuna-imago
bash bin/run-tests.sh all          # 19 isolated targets; one fresh SBCL process each
bash bin/build-echo-image.sh       # produces ./echo-agent (~63 MB full-agent profile)
```

No install step. The system loads via ASDF from this directory; nothing
gets dropped into `/usr/local`.

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- USAGE -->
## Usage

### Try it

```sh
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
real Anthropic provider and you have a working LLM-backed agent in another
~10 lines of customisation (see [Build your own agent](#build-your-own-agent)).

<p align="right">(<a href="#readme-top">back to top</a>)</p>


### Redefine in flight

The headline claim — "redefine any function in flight, then save" — works
because methods are late-bound and the SBCL heap is the artifact.

```lisp
(in-package :anuna-imago)

;; Build and start an agent in a live REPL.
(defparameter *sup*   (make-supervisor 'live-sup))
(defparameter *agent* (build-echo-agent))
(spawn-agent! *sup* *agent*)

(getf (ask-agent *agent* "hi") :text)
;; => "echo: hi"

;; Redefine a provider method. CLOS swaps the dispatch in place — the
;; running supervisor, the spawned agent, its mailbox: all untouched.
(defmethod provider-stream! ((p stub-provider) agent message)
  (declare (ignore agent))
  (let* ((c     (if (listp message) (getf message :content) message))
         (frame (list :text (format nil "shouted: ~A!" (string-upcase c))))
         (cell  (cons nil (list frame))))
    (lambda () (pop (cdr cell)))))

(getf (ask-agent *agent* "hi") :text)
;; => "shouted: HI!"        ; same process, no restart

;; Snapshot the live image. The redefined method is in the saved heap.
(send! (agent-mailbox *agent*) :shutdown)
(drain-supervisor! *sup*)
(save-image! "shouty-agent" :toplevel 'agent-main)
```

```sh
$ ./shouty-agent --echo "hello"
shouted: HELLO!
```

The patch survives because the binary *is* the heap. There's no source
tree to redeploy and no rebuild step — the running image was edited and
then frozen. The same path works for any harness method: tool dispatch,
hook handlers, supervisor restart policy.

<p align="right">(<a href="#readme-top">back to top</a>)</p>


### Mental model

A running agent is **one OS process** holding an SBCL image:

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

The **turn loop** is the heart. For each inbound ask:

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

Six seams to know about:

* **Methods** are `defmethod` — redefine at the REPL, the next call uses
  the new version.
* **Hooks** at `:on-user-input`, `:on-tool-call`, `:on-tool-result`,
  `:on-turn-complete`, `:on-agent-spawn`, `:on-agent-crash`. First
  handler to return `:veto` aborts the chain.
* **Providers** are CLOS classes implementing `provider-stream!`. Stubs
  for tests, Anthropic in production; CON-005 contract preserved so
  Bedrock and Vertex drivers fit the same shape (not yet implemented).
* **Transports** are abstract — `wss-transport` for production, an
  in-memory `mock-transport` for tests.
* **Reasoner** integration is IPC-only. At `:on-tool-call` the harness
  asks a Spindle defeasible-logic theory whether the call is
  `(forbidden …)`; a +Δ or +∂ verdict vetoes before the handler runs.
* **Identity** is per-agent: each agent can carry an `agent-identity`
  with an Ed25519 keypair and a `did:key:…` DID. Gateways auth via the
  `(auth-did …)` frame; `:clean t` zeros the private key before save.

<p align="right">(<a href="#readme-top">back to top</a>)</p>


### Built-in tools

Ten tools auto-register when `imago` loads. They cover harness introspection
and a few utilities. A bound agent can dispatch only names in its `:tools`.
Direct operator dispatch remains available when `*current-agent*` is unbound.

| Name | Returns |
|---|---|
| `harness-list-tools` | All registered tool names |
| `harness-describe-tool` | `{description, permission, schema}` for a name |
| `harness-list-hooks` | Hook keys + handler counts |
| `harness-version` | Harness version string |
| `harness-now` | Current UTC time, ISO-8601 |
| `harness-describe-agent` | Calling agent's id, capability, system prompt, tools, state |
| `harness-query-receipts` | Last N receipt-log entries with `:limit` |
| `harness-uuid` | Fresh UUID v4 |
| `harness-stats` | Process metrics: uptime, mailbox depth, tool count |
| `harness-query-theory` | Inspect a Spindle theory query (does NOT veto) |

```lisp
;; Wire all ten into an agent:
(make-instance 'agent ... :tools *builtin-tool-names*)
```

#### Opt-in: fileops

File operations are gated behind an explicit installer. The reasoner is
expected to gate dangerous calls — at minimum, `(forbidden harness-write-file "/etc/...")`
style rules — before exposing these to an agent.

```lisp
(install-fileops-tools!)        ; registers the three below
(make-instance 'agent ...
  :tools (append *builtin-tool-names* *fileops-tool-names*))
```

| Name | Permission | Returns |
|---|---|---|
| `harness-read-file` | `:read` | UTF-8 content + `:length` + `:truncated` (truncates at `:max-chars`, default 1MB) |
| `harness-write-file` | `:write` | `{:status :ok :length …}`; `:append t` to append |
| `harness-list-directory` | `:read` | Sorted file + subdirectory names |

What's deliberately **not** shipped: HTTP fetch, web search, shell exec.
Those are exactly the "agent framework" abstractions this project's
bitter-lesson stance refuses — schema-volatile across providers, and
better served by MCP servers or per-project tool modules.

#### Plugins (opt-in ASDF subsystems)

Capabilities that don't belong in the core 2k LOC harness ship as
plugins under [`plugins/`](./plugins). Load with
`(ql:quickload :imago/<plugin>)`; main `:imago` system stays unaware.

| Plugin | Load with | Provides |
|---|---|---|
| `imago/openrouter` | `(ql:quickload :imago/openrouter)` | OpenAI-compatible driver for any [OpenRouter](https://openrouter.ai)-served model. Pass the slug as `:model`, e.g. `"z-ai/glm-5.1"`, `"openai/gpt-4o"`, `"anthropic/claude-opus-4-7"` |
| `imago/zai` | `(ql:quickload :imago/zai)` | Z.ai GLM Coding Plan provider (Anthropic-compatible). Thin wrapper over the existing Anthropic driver pointed at `api.z.ai/api/anthropic`. Optional opencode `auth.json` key reader |
| `imago/evolution` | `(ql:quickload :imago/evolution)` | External control plane for immutable candidates, signed evaluations, eligibility decisions, promotion, and rollback |

```lisp
;; --- Example A: any model via OpenRouter ----------------------------
(ql:quickload :imago/openrouter)
;; OPENROUTER_API_KEY in env, or :api-key here.
(let ((provider (anuna-imago:make-openrouter-provider
                  :model "z-ai/glm-5.1"))) ; or "openai/gpt-4o", "anthropic/claude-opus-4-7", …
  (make-instance 'anuna-imago:agent
                 :provider provider
                 :system-prompt "You are concise."
                 :tools '(anuna-imago:harness-list-tools)))

;; --- Example B: Z.ai GLM Coding Plan (Anthropic-compatible) ---------
(ql:quickload :imago/zai)
(let ((provider (anuna-imago:make-zai-coding-provider
                  :model "glm-5.1"                       ; or glm-5-turbo / glm-4.7 / glm-4.5-air
                  ;; Pull the key from opencode's auth.json so you don't
                  ;; have to re-paste it. Pass NIL to skip and use
                  ;; ANTHROPIC_API_KEY env instead.
                  :opencode-slug "zai-coding-plan")))
  (make-instance 'anuna-imago:agent
                 :provider provider
                 :system-prompt "You are concise."
                 :tools '(anuna-imago:harness-list-tools)))
```

Both provider plugins reuse the existing `provider-stream!` contract. The same
agent definition, supervision, hook chain, and self-modification port
work unchanged with any served model.

##### Harness evolution control plane

[HarnessDev](https://arxiv.org/abs/2609.01437) motivates a strict distinction
between producing a harness mutation and establishing an improvement. The
optional `imago/evolution` system turns that distinction into operator-side
governance and evidence infrastructure.

```lisp
(ql:quickload :imago/evolution)
```

Loading `imago` alone does not load this package, create a store, or register
tools. Candidate processes do not receive the control-plane package, store
path, or private identities.

```text
active image -> freeze candidate -> evaluate repeated held-out runs
                                      |
baseline <------------------------- decide
                                      |
                      authorize -> canary/active -> rollback
```

The operator workflow has five stages:

1. `freeze-candidate!` copies an image and writes a signed, content-addressed
   manifest. The manifest records lineage, surface digests, changes, budgets,
   and activation evidence.
2. `record-evaluation!` appends signed runs from trusted executors and
   evaluators. Each record binds its campaign, benchmark, replicate,
   evaluation plan, executor configuration, scorer configuration, completion
   attestation, and structured activation evidence.
3. `make-decision!` consumes every current held-out event for one campaign and
   the compared candidates. It requires exact paired cells, complete matching
   replicate templates, a single evaluation plan, and transfer across every
   executor-and-configuration cohort. It reports every satisfied or failed
   gate.
4. `promote-candidate!` atomically changes `:canary` or `:active` after a
   trusted external authorizer signs an eligible, current decision.
5. `rollback-pointer!` restores the recorded prior candidate and appends a
   signed rollback event.

A comparison cell binds the benchmark, task, replicate, executor, evaluator,
evaluation plan, executor configuration, and scorer configuration. Baseline
and candidate cell multisets must match exactly, and duplicate candidate cells
are rejected. The ledger also rejects the same
`(campaign-id, benchmark-id, task-id)` tuple in an exposed split and the
held-out split.

Every actor uses an Imago `did:key` identity. Store construction fixes the
executor, evaluator, and authorizer trust rosters.

| Actor | Authority and evidence |
|---|---|
| Store authority | Signs each terminal ledger head |
| Creator | Signs the candidate manifest and freeze event |
| Executor | Belongs to the trusted executor roster and signs each run |
| Evaluator | Belongs to the disjoint evaluator roster and countersigns each run |
| Authorizer | Belongs to a roster disjoint from executors and evaluators, differs from both compared creators, and signs decisions and pointer events |

Store creation rejects overlap among the executor, evaluator, and authorizer
rosters. A held-out cell also requires its creator, executor, and evaluator to
be pairwise distinct.

The decision keeps these evidence dimensions separate:

| Dimension | Recorded value | Decision use |
|---|---|---|
| Correctness | Boolean for each exact paired cell | Every baseline-correct cell has a correct candidate match |
| Capability | Integer millionths by cell, replicate, and executor configuration | The minimum replicate delta and every executor cohort meet the configured positive threshold |
| Activation | Sorted `:runtime-hit` or `:reachable` records | Every changed component has a candidate-image-bound `:runtime-hit`; reachability alone is diagnostic |
| Execution tokens | Input plus output tokens | Separate totals, per-event means, signed delta, and maximum-increase gate |
| Runtime cost | Integer micro-US dollars | Separate totals, per-event means, signed delta, and maximum-increase gate |

Duration and candidate development cost remain signed report inputs. A
capability gain cannot offset a correctness, activation, token, or runtime-cost
failure.

The default evidence floor is three held-out repetitions for each candidate
and two distinct executors. The default minimum capability delta is one
millionth. The maximum execution-token and runtime-cost increases both default
to zero. Counts below two, a non-positive capability threshold, or negative
efficiency limits are rejected.

The store uses an append-only hash chain and a separately signed terminal
head. Creators sign freezes, executors and evaluators sign runs, and
authorizers sign decisions and pointer changes. Candidate verification
recomputes image and lineage digests, and freeze never overwrites an existing
candidate.

Persisted readers accept only the closed canonical grammar. They enforce size
and depth bounds before semantic effects and never intern input symbols.
Managed roots reject symlink replacement, while managed files require regular
filesystem entries.

The external evaluator process and its operator-owned filesystem permissions
form the control-plane trust boundary. The subsystem detects malformed data,
broken chains, stale decisions, and candidate-byte changes inside that
boundary. It does not resist an operator who restores a complete earlier
ledger and signed head. Operators retain responsibility for private-key
custody, signer isolation, evaluation plan quality and secrecy, and benchmark
execution. A signed `:run-complete-p` value is a runner attestation; the
control plane does not inspect the run. Version 0.2 assumes one writer per
store, with multi-process coordination and crash recovery supplied externally.

This subsystem is not an optimizer and does not generate mutations. It is not
an OS sandbox for untrusted Lisp. It governs evidence and promotion around an
external benchmark runner.

Run its focused and supporting gates with these exact targets:

```sh
bash bin/run-tests.sh m4          # bound-agent tool authorization
bash bin/run-tests.sh m10         # strict proof-result recognition
bash bin/run-tests.sh m12         # fail-closed self-modification path
bash bin/run-tests.sh openrouter  # multi-turn provider tool feedback
bash bin/run-tests.sh evolution   # complete SPEC-014 control-plane suite
bash bin/run-tests.sh all         # all 19 targets in isolated SBCL processes
bash bin/test-scaffolder.sh       # custom factory entrypoint smoke
```

##### Multi-turn experiment runner

[`examples/glm-self-mod-experiment.lisp`](./examples/glm-self-mod-experiment.lisp)
is a research instrument with two modes, driven by
[`bin/run-experiment.sh`](./bin/run-experiment.sh):

| Mode | What | Question it answers |
|---|---|---|
| **Prescribed** (default) | Fixed six-prompt protocol: tool-discovery → plan → implement → verify → forbidden-probe → rollback | Do the safety mechanisms catch the obvious attacks? Comparable across runs. |
| **Goal-driven** (`--goal "..."`) | Agent is told a goal in its system prompt and driven by `Continue.` each turn until it replies `GOAL ACHIEVED:` or hits `--turns` (default 8) | Can the model decompose a real task using the port? Open-ended; not directly comparable. |

```sh
./bin/run-experiment.sh                                    # prescribed
./bin/run-experiment.sh --model glm-4.7                    # different model
./bin/run-experiment.sh --goal "Define a memoize macro and use it
                                to wrap a slow function."
./bin/run-experiment.sh --goal "..." --turns 12            # longer run
./bin/run-experiment.sh --dry-run --goal "..."             # show what would run
```

The script reads your Z.ai key from `~/.local/share/opencode/auth.json`
under the `zai-coding-plan` slug — no env vars to set. Reports land
under `/tmp/imago-experiments/<timestamp>-glm{-goal}-experiment.md`
with: starting/ending state, per-turn deltas (audit log appendices,
origin-index updates, rollback-register pushes, reasoner-trace facts
correlated by `form-id`), audit-log tally, falsification checklist,
and failure modes to scan for.

Both modes use a floor-only stub reasoner that mimics the shipped
`theories/self-modification-floor.spl`, so no live Spindle service is
required.

**What goals can actually work**: the agent can `defun` / `defclass` /
`defmacro` freely, but most of the harness's core dispatch surface is
in `*safety-layer-symbols*` — so goals like *"add logging to all tool
calls"* will hit `:vetoed` because the obvious implementation
mentions `dispatch-tool!`. Goals that fit the v0.1 floor:

- "Add persistent memory to yourself." (Empirically achieved by GLM 5.1
  in 6 turns: 18 symbols redefined, 19 rollback records, 3 legitimate
  vetoes — see [`architecture/EXPERIMENT-LOG.md`](./architecture/EXPERIMENT-LOG.md).)
- "Build a small library of string utilities (palindrome, capitalize
  words, etc.) and demonstrate calling them on test inputs."
- "Define a memoize macro and apply it to a slow function you also define."
- "Implement a simple in-memory key-value cache as a defclass with
  put/get methods, and exercise it."

When the floor fires, the rejected reply carries a `:hint` field naming
the *category* of the offending mention — e.g. `EVAL-CLASS` for any of
`eval` / `read` / `load` / `compile` — and suggests an alternative class
of operations. The `harness-list-safety-layer` tool also accepts
`:by-category t` to return categorised symbols with rationale up front.
Without these, agents tend to retry from the same forbidden category one
symbol at a time; with them, GLM 5.1 typically pivots to a working
approach in 1-2 vetoes.

Wrapping/replacing existing harness behavior is largely deferred to a
future `harness-advise` tool (ADR-005, v0.2). The empirical journey
that shaped this surface — six goal-driven runs, four follow-up fixes —
is logged in [`architecture/EXPERIMENT-LOG.md`](./architecture/EXPERIMENT-LOG.md).

#### Opt-in: self-modification port

A `harness-eval` tool — submit a Common Lisp source form, get it
evaluated in the harness's runtime — plus five introspection siblings
live in [`examples/self-modifying.lisp`](./examples/self-modifying.lisp)
under explicit author opt-in. The file is **not** loaded by ASDF; the
author must `(load …)` it and call `(install-self-modification-tools!)`
after loading a defeasible-logic theory. Three layers gate every
`harness-eval` call:

1. **Pre-filter** — fast structural denylist (`unintern`,
   `delete-package`, `(setf (symbol-function …) …)`, `eval`, `load`,
   reader-macro mutators, `sb-thread:interrupt-thread`, `defmethod`
   against any safety-layer generic, etc.).
2. **Reasoner** — the form is lifted to facts (operator, target,
   defmethod-targets, free-symbols incl. body-buried) and the active
   Spindle theory is queried for `(forbidden eval-call …)`. The shipped
   floor invariants block any mention of any safety-layer symbol.
3. **Handler** — evaluates in a worker thread under a timeout (default
   1 s, max 30 s), captures method-set diffs for rollback, writes a
   verbatim audit-log entry, updates a queryable origin index.

The full surface is specified in
[`specs/SPEC-012-self-modification-port.md`](./specs/SPEC-012-self-modification-port.md);
the in-context adversarial review of CON-002/003 found 11 bypass shapes
and is recorded in
[`architecture/ADR-012-self-mod-adversarial-review.md`](./architecture/ADR-012-self-mod-adversarial-review.md).
Operators can `(unregister-tool! 'harness-eval)` from the REPL at any
time and re-snapshot the image without it.

```lisp
;; Opt-in pattern:
(load "examples/self-modifying.lisp")
(let* ((floor (uiop:read-file-string "theories/self-modification-floor.spl"))
       (handle (load-theory floor)))
  (install-invariant-filter! :theory-handle handle)
  (install-self-modification-tools!))   ; → :ok | :no-active-theory
```

Six tools register together (`*self-modification-tool-names*`). The five
siblings give the LLM agent enough runtime context to use `harness-eval`
without trial-and-error against the safety stack:

| Name | Permission | Returns |
|---|---|---|
| `harness-eval` | `:eval` | The evaluated value, or a structured rejection / veto / error / timeout plist (see CON-001 prose in the tool's `:description`) |
| `harness-list-safety-layer` | `:read` | The forbidden symbol set, optionally filtered by `:prefix` — "what NOT to redefine" |
| `harness-redefine-history` | `:read` | Per-symbol summary `{:symbol :event-count :latest}`, or with `:symbol` the most-recent N events for that symbol |
| `harness-list-rollbacks` | `:read` | Lightweight summary of `*rollback-register*` — index, kind, symbol, installed-at, rolled-back |
| `harness-rollback` | `:execute` | Re-installs the prior method/fdefinition for `:index`. Returns `{:status :ok|:no-such-record|:already-rolled-back :index N}`. Itself audited |
| `harness-query-self-mod-receipts` | `:read` | Recent harness-eval audit-log entries (distinct from `harness-query-receipts`, which reads the SPEC-011 ASK/reply log) |

<p align="right">(<a href="#readme-top">back to top</a>)</p>


### Quick start: scaffold a new project

```sh
bash bin/new-agent.sh my-agent ../my-agent
cd ../my-agent
bash bin/build.sh
./my-agent --echo "hi"
```

This vendors imago into `../my-agent/imago/`, generates a starter
project with a build script, smoke test, and demonstrative agent
file. See `bin/new-agent.sh` for what gets stamped where.


### Build your own agent

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

```sh
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

`./my-agent` is now a self-contained ~63 MB binary you can `scp` to any
machine without SBCL installed. `:clean t` (default) flushes credentials,
private keys, async pools, and open log handles before the save — see
[`architecture/CHECKING.md`](./architecture/CHECKING.md) for the
checklist.

To make the agent reachable from a CBCL router, build a `gateway` over
a `wss-transport`. Pass either a bearer-token string or an
`agent-identity` (Ed25519 + did:key) for the `:identity` slot — the
auth handshake dispatches on type:

```lisp
(let* ((id (generate-identity))                 ; fresh did:key identity
       (tr (make-wss-transport "wss://router.example/agent/v1"))
       (gw (make-gateway :id 'my-gw
                         :transport tr
                         :identity id            ; → (auth-did <DID> …)
                         :capability "echo:say"
                         :agent agent)))
  (register-identity-for-clean! id)             ; private key stripped on save
  (gateway-connect! gw)
  (gateway-start-pumps! gw))
```

`test/m7-tests.lisp` shows the full lifecycle against a mock router;
`test/m7-wss-tests.lisp` exercises the same surface against a real
WebSocket round-trip on loopback.

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- PROJECT LAYOUT -->
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
│   ├── builtin-tools.lisp            harness-{list,describe,uuid,stats,…}
│   ├── fileops-tools.lisp            opt-in harness-{read,write,list-dir}
│   ├── turn-loop.lisp                default per-message loop
│   │
│   ├── receipt-log.lisp              content-addressed audit log
│   ├── save-image.lisp               save-image! + :clean checklist
│   │
│   ├── gateway.lisp                  CBCL Router Client — receiver side
│   ├── producer-gateway.lisp         CBCL Router Client — producer side
│   ├── identity.lisp                 Ed25519 + did:key, sign/verify
│   ├── wss-transport.lisp            websocket-driver-backed transport
│   ├── cbcl-ffi.lisp                 CBCL parser via FFI to cbcl-rs
│   ├── reasoner.lisp                 Spindle IPC + invariant filter
│   ├── self-modification.lisp        SPEC-012 harness-eval (handler,
│   │                                 prefilter, lift, origin index, rollback)
│   │
│   └── providers/
│       ├── stub.lisp                 canned-response provider for tests
│       └── anthropic.lisp            Messages API + mockable HTTP
│
├── test/                             milestone suites (M1–M11, M12) plus
│                                     M7-WSS, M7-Producer, builtin-tools,
│                                     fileops-tools, identity
├── examples/
│   ├── echo.lisp                     reference echo agent
│   └── self-modifying.lisp           opt-in install-self-modification-tools!
│                                     (NOT registered by ASDF — REQ-001)
├── theories/
│   └── self-modification-floor.spl   SPEC-012 floor invariants (Spindle)
├── specs/
│   ├── SPEC-012-self-modification-port.md  agent self-modification port
│   └── SPEC-014-harness-evolution-control-plane.md
│                                       measured harness evolution
├── architecture/
│   ├── ADR-001-image-runtime.md      why SBCL (not ECL)
│   ├── ADR-002-identity.md           why did:key (not did:web/plc)
│   ├── ADR-012-self-mod-adversarial-review.md
│   │                                 11 bypass shapes + IMPL+ amendments
│   ├── ADR-013-self-mod-oq-decisions.md
│   │                                 OQ-001..004 resolutions
│   └── CHECKING.md                   :clean t audit checklist
├── plugins/                          opt-in subsystems — load via
│   ├── openrouter/                   (ql:quickload :imago/<plugin>)
│   │   ├── openrouter.lisp           OpenRouter (OpenAI-compatible) driver
│   │   └── test.lisp                 stubbed-HTTP test suite
│   ├── zai/
│   │   ├── zai.lisp                  Z.ai GLM Coding Plan (Anthropic-compat)
│   │   └── test.lisp                 stubbed-HTTP test suite
│   └── evolution/
│       ├── evolution.lisp            signed evolution control plane
│       └── test.lisp                 SPEC-014 contract and attack suite
├── plan.spl                          SPEC-011 implementation plan (hence)
├── plan.spec-012.spl                 SPEC-012 implementation plan (hence)
├── plan.spec-014.spl                 SPEC-014 Elephant plan snapshot
└── .github/workflows/ci.yml          matrix CI + LOC-budget gate
```

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- API REFERENCE -->
## API Reference

Compact signature reference for the surface a user-facing agent author
calls. The full export list is in [`src/packages.lisp`](./src/packages.lisp);
docstrings live with the definitions in `src/`.

### Agents & supervision

```lisp
(make-instance 'agent :id …  :capability …  :provider …  :system-prompt …
                      :tools '(…))                      → agent
(agent-id|agent-capability|agent-mailbox|agent-provider
 |agent-tools|agent-system-prompt|agent-theory|agent-state) agent
*current-agent*                                  ; bound during a turn

(make-supervisor id &key max-restarts within-seconds parent) → supervisor
(add-child! supervisor id start-fn)              → id
(start-supervisor! supervisor)                   → supervisor
(spawn-agent! supervisor agent)                  → agent
(drain-supervisor! supervisor &key timeout)      → supervisor
(force-restart! supervisor child-id)             → child-id | nil
(list-children supervisor)                       → ((:id … :state … :restarts …) …)
(child-state-of supervisor child-id)             → keyword | nil
(sup-state supervisor)            → :stopped | :running | :draining | :failed
```

### Mailboxes & messaging

```lisp
(make-mailbox)                                   → mailbox
(send! target message)                           → message      ; defgeneric
(receive! mailbox &key timeout)        → message | :timeout | :closed
(peek-mailbox mailbox)                           → message | nil
(mailbox-depth mailbox)                          → integer
(close-mailbox! mailbox)
;; SEND! is a generic; default method is on MAILBOX. GATEWAY adds a method
;; that forwards as a reply over the wire — same call site, two backends.

(make-ask content &key reply-to meta)            → ask-plist
(ask-message-p msg)                              → boolean
(ask-content msg)                                → string
(ask-reply-to msg)                               → mailbox-or-gateway
(make-reply text &key tool-results meta)         → reply-plist
(ask-agent agent content &key timeout)           → reply-plist  ; convenience
```

### Hooks

```lisp
(register-hook key handler)                      → handle
(remove-hook handle)                             → t | nil
(run-hook key agent &rest args)                  → value | :veto | nil
(list-hooks &optional key)
(clear-all-hooks)
*hook-keys*           ; :on-user-input :on-tool-call :on-tool-result
                      ; :on-turn-complete :on-agent-spawn :on-agent-crash
*excluded-hook-keys*  ; :on-prompt-build :on-stream-token (registration errors)
```

### Tools

```lisp
;; Registration
(define-tool name :description … :permission … :schema … :handler …)
(register-tool! tool)                            → name
(unregister-tool! name)                          → t | nil
(find-tool name)                                 → tool | nil
(list-tools)                                     → (name …)
(clear-all-tools)
(dispatch-tool! name args-plist)                 → handler-return

;; Schema → provider format
(schema->json-schema schema)                     → CL alist tree
(json-schema->schema json-data)                  → schema     ; round-trip
(tool->anthropic-descriptor tool)
                  → ((:name … :description … :input_schema …))

;; Built-ins (auto-registered when imago loads)
*builtin-tool-names*  ; harness-list-tools, harness-describe-tool,
                      ; harness-list-hooks, harness-version, harness-now,
                      ; harness-describe-agent, harness-query-receipts,
                      ; harness-uuid, harness-stats, harness-query-theory
(install-builtin-tools!)                         ; idempotent re-install

;; Fileops (opt-in)
*fileops-tool-names*  ; harness-read-file, harness-write-file,
                      ; harness-list-directory
*fileops-max-read-chars*                         ; default 1048576
(install-fileops-tools!)
(uninstall-fileops-tools!)
```

### Providers

```lisp
(provider-name provider)                         → string
(provider-stream! provider agent message)        → stream-handle
(stream-next-frame! stream)
   → (:text STRING) | (:tool-use ID NAME ARGS) | (:error PLIST) | :done

;; Stub (canned responses for tests)
(make-stub-provider &key responder)              → provider

;; Anthropic
(make-anthropic-provider &key api-key model base-url max-tokens)  → provider
(build-request provider message agent)           → hash-table
(auth-headers provider)                          → ((header . value) …)
*anthropic-http-post* (url &key headers content) → string  ; mockable
```

### Gateway & transport

```lisp
;; Receiver gateway — agent serves asks for its registered capability.
(make-gateway :id … :transport … :identity … :capability …
              :agent … :receipt-log … :heartbeat-interval …)  → gateway
(gateway-connect! gateway &key timeout)          → t
(gateway-start-pumps! gateway)                   ; recv + heartbeat threads
(gateway-disconnect! gateway)
(gateway-state gateway)
   → :disconnected | :authenticating | :ready | :draining | :failed

;; Producer gateway — agent issues asks via the router and awaits replies.
(make-producer-gateway :id … :transport … :identity …
                       :heartbeat-interval …)             → producer-gateway
(producer-connect! gw &key timeout)              → t
(producer-start-pumps! gw)
(producer-ask! gw capability body)               → (values mailbox receipt-id)
(producer-call! gw capability body &key timeout)
   → reply-string | :timeout | (:error :rejected …)
(producer-disconnect! gw)
(producer-state gw) → :disconnected | :authenticating | :ready | :draining | :failed
(producer-in-flight-count gw)                    → integer

;; Transport protocol (defgenerics; specialise to add new transports)
(transport-open! tr)
(transport-send! tr string)
(transport-recv! tr &key timeout)        → string | :timeout | :closed
(transport-close! tr)
(transport-connected-p tr)                       → boolean

(make-wss-transport url &key headers)            → wss-transport
*wss-open-timeout-seconds*                       ; default 10

(make-mock-transport)                            → mock-transport
(mock-feed! tr string)             ; inject inbound (for tests)
(mock-drain! tr &key timeout)      ; read what gateway sent
```

### Identity (did:key, Ed25519)

```lisp
(generate-identity)                              → agent-identity
(identity-did identity)                          → "did:key:z..."
(identity-public-key-bytes identity)             → octet-vector (32 bytes)
(identity-private-key identity)                  → ironclad-priv | nil  ; nil after :clean
(sign-string identity string)                    → octet-vector (64 bytes)
(verify-signature did string signature-bytes)    → boolean

;; DID encoding helpers (W3C did:key, Ed25519 multicodec 0xed01)
(encode-did-key 32-byte-pubkey)                  → "did:key:z..."
(parse-did-key did-string)                       → 32-byte-pubkey | nil
(bytes->hex octet-vector) / (hex->bytes string)
(base58btc-encode octet-vector) / (base58btc-decode string)

;; :clean integration — strips private key before save-image!
(register-identity-for-clean! identity)
(clear-identity-private-key! identity)

;; Auth handshake helper
(make-did-auth-payload did iso-timestamp)        → string  ; signed payload
(make-did-auth-frame identity)
   → "(auth-did <did> <iso-ts> <hex-sig>)"

;; Wire identity into an agent or gateway:
(make-instance 'agent ... :identity (generate-identity))
(agent-did agent)                                ; convenience
(make-gateway ... :identity (generate-identity)) ; uses (auth-did …) instead of (auth …)
```

### Reasoner

```lisp
*reasoner-ipc-call* (op &rest args)              ; injectable IPC; tests stub
*active-theory-handle*                           ; bound by install-…!

(load-theory text-or-path)                       → handle
(assert-fact! handle fact)                       → ack
(retract-fact! handle fact)                      → ack
(query handle goal)
   → (:tag :+delta|:+partial-delta|:-delta|:-partial-delta
      :derivation … :time-ms …)
(what-if handle goal facts)                      → proof-result
(why-not handle goal)                            → counter-derivation
(proof-result-positive-p result)                 → generalised-boolean

(install-invariant-filter! :theory-handle handle)  → hook-handle
(uninstall-invariant-filter!)
;; Wires invariant-filter-hook on :on-tool-call. Reasoner verdicts of
;; +Δ or +∂ on (forbidden TOOL ARGS) → :VETO before dispatch.
```

### Receipt log

```lisp
(open-receipt-log path)                          → log
(append-receipt! log &key receipt-id direction dialect verb body
                       agent-id producer-id status)        → entry-plist
(read-receipts path)                             → (entry-plist …)
(close-receipt-log! log)
(content-hash body)                              → hex-string  ; sb-md5
(iso-8601-now)                                   → "YYYY-MM-DDTHH:MM:SSZ"
(register-receipt-log-for-clean! log)            ; for :clean t flush
```

### Self-modification (SPEC-012, opt-in)

```lisp
;; Registration — load examples/self-modifying.lisp first; not in ASDF.
(install-self-modification-tools! &key audit-log-path)
   → :ok | :no-active-theory | :already-installed
(uninstall-self-modification-tools!)             → :ok

;; Tool dispatch (the handler returns a plist; never raises)
;; CON-001 contract:
;;   (:status :ok        :phase :evaluated   :value … :stdout … :elapsed-ms …)
;;   (:status :rejected  :phase :pre-filter  :rule … :reason …)
;;   (:status :vetoed    :phase :reasoner    :goal … :derivation … :time-ms …)
;;   (:status :error     :phase :evaluation  :condition-type … :message …)
;;   (:status :timeout   :phase :evaluation  :elapsed-ms …)

;; Pre-filter (CON-002 + ADR-012 §A1)
*prefilter-denylist*                             ; alist op → rule keyword
(%harness-eval-prefilter form)                   → :pass | (:status :rejected …)

;; Lift (CON-003 + ADR-012 §A4)
(%lift-form form)
   → (:operator … :target … :qualifier … :specialisers …
      :free-symbols … :defmethod-targets … :defgeneric-targets …
      :defun-targets …)

;; Safety-layer set — defeasible mentions/2 floor (ADR-012 §A1)
*safety-layer-symbols*

;; Origin index (CON-005)
*redefine-history*                               ; hash-table sym → events
(redefine-history symbol)                        → (event …)
(last-redefinition symbol)                       → event | nil
(all-redefined-symbols)                          → (sym …)

;; Rollback register (CON-006 + ADR-013 OQ-004 union shape)
*rollback-register*                              ; vector of records
(rollback! index)                                → :ok | :no-such-record |
                                                   :already-rolled-back
(rollback-records)                               → (record …)
(find-rollback-records-for symbol)               → (record …)

;; Result-printing bound (ADR-013 OQ-003)
*harness-eval-result-truncate-bytes*             ; default 4096

;; Audit log instance — opened by install-self-modification-tools!
*harness-eval-audit-log*                         ; receipt-log instance | nil
```

### Harness evolution control plane (SPEC-014, opt-in)

Load `imago/evolution` before resolving these symbols. They live in the
`anuna-imago.evolution` package and do not enter the core package.

```lisp
;; Store lifecycle and trust rosters. Roster entries are did:key strings.
(open-evolution-store path
  &key authority trusted-executors trusted-evaluators trusted-authorizers)
                                                    → evolution-store
(close-evolution-store store)                       → t

;; Freeze and verify content-addressed candidates.
(freeze-candidate! store source-image
  &key parent-id parent-image-sha256 creator created-at
       theory-fingerprint prompt-schema-sha256 tool-schema-sha256
       changed-components budgets activation-evidence) → manifest-plist
(read-candidate-manifest store candidate-id)        → manifest-plist
(verify-candidate store candidate-id)                → boolean

;; Append signed runs and derive a baseline-relative decision.
(record-evaluation! store
  &key run-id campaign-id benchmark-id split task-id replicate-index
       evaluation-plan-sha256 executor-config-sha256 scorer-config-sha256
       candidate-id executor evaluator run-complete-p task-correct-p
       capability-score-micros activation-evidence duration-ms input-tokens
       output-tokens estimated-cost-microusd)
                                                    → evaluation-event
(make-decision! store baseline-id candidate-id
  &key campaign-id minimum-held-out-repetitions
       minimum-distinct-executors minimum-capability-delta-micros
       maximum-execution-token-increase
       maximum-runtime-cost-increase-microusd authorizer) → decision-event

;; Each activation entry has this exact closed shape. Lists are sorted and unique.
(:component "component-name"
 :kind :runtime-hit                  ; or :reachable for diagnostics only
 :artifact-sha256 "sha256-digest")

;; Change operator pointers. These calls reject bound agent contexts.
(promote-candidate! store decision &key pointer authorizer)
                                                    → promotion-event
(rollback-pointer! store pointer &key authorizer)   → rollback-event
(read-pointer store pointer)                        → candidate-id | nil

;; Inspect and verify persisted evidence.
(read-ledger store)                                 → (event-plist …)
(read-ledger-head store)                            → head-plist
(verify-ledger store)                               → boolean
(canonical-bytes value)                             → utf-8-octet-vector

;; Confined path accessors.
(candidate-directory store candidate-id)            → pathname
(candidate-image-path store candidate-id)           → pathname
(candidate-manifest-path store candidate-id)        → pathname
(ledger-path store)                                 → pathname
(ledger-head-path store)                            → pathname
(pointer-path store pointer)                        → pathname
```

### Image distribution

```lisp
(save-image! path &key toplevel clean executable)  ; DOES NOT RETURN
(pre-save-clean!)                                ; manually trigger checklist
*clean-checklist*  ; :close-receipt-log :shutdown-hook-async-pool
                   ; :drop-credentials :force-gc
(register-credential-eraser! thunk)
*boot-time*                                      ; universal-time at load
*version*                                        ; "0.1.0"
(agent-main &optional factory)                   ; toplevel for saved images
```

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- ROADMAP -->
## Roadmap

- [x] M0  Project scaffold (asd, packages, ADR-001-image-runtime)
- [x] M1  Supervisor + mailbox + agent CLOS
- [x] M2  Hook system with stance enforcement
- [x] M3  `define-tool` + JSON Schema as CL data
- [x] M4  Turn loop + stub provider + echo example
- [x] M5  Append-only content-addressed receipt log
- [x] M6  CBCL parser via FFI to cbcl-rs
- [x] M7  Gateway with transport abstraction
- [x] M7-WSS  Production WebSocket transport
- [x] M8  Anthropic provider (non-streaming)
- [x] M9  Image distribution (`save-image!` + `:clean`)
- [x] M10 Reasoner IPC + invariant filter
- [x] M11 Drainable shutdown + release smoke
- [x] Built-in introspection tools (10 default, auto-registered)
- [x] Producer-gateway (cross-process agent composition)
- [x] Opt-in fileops tools (`install-fileops-tools!`)
- [x] did:key cryptographic identity (Ed25519, ADR-002)
- [x] SPEC-012 self-modification port — **implemented** (`harness-eval`,
      opt-in via `examples/self-modifying.lisp`; ADR-012 / ADR-013)
- [x] SPEC-012 t10 — save-image! survival integration test (TEST-016)
- [x] SPEC-012 t11 — full SPEC-012 test corpus (TEST-010/017 +
      NFR benchmarks TEST-018..TEST-022, 1000-form FP corpus under
      `test/fixtures/`)
- [x] SPEC-012 t12 — final adversarial review (SELF-MOD-REVIEW.md);
      fixed BLOCKER-1 setf/setq safety-variable bypass (ADR-014)
- [x] SPEC-014 optional harness evolution implementation and focused tests
- [ ] R4 frame-level signing on every CBCL message (needs cbcl-rs FFI)
- [ ] Streaming SSE for the Anthropic provider
- [ ] CI matrix M6 step (cbcl-rs cdylib build)
- [ ] Bedrock provider driver
- [ ] Vertex provider driver

Measured with `wc -l`, top-level `src/*.lisp` contains **4,338 lines** and
`plugins/evolution/evolution.lisp` contains **2,393 lines**. The combined
`test/*.lisp` and `plugins/*/test.lisp` scope contains **7,800 lines**. The
aggregate runner executes **19 targets** in fresh SBCL processes. Its evolution
target currently runs **33 groups and 566 checks**.

See the [open issues](https://codeberg.org/anuna/imago/issues) for
proposed features and known issues.

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- CONTRIBUTING -->
## Contributing

Contributions are welcome. The project is small enough that a PR-and-discuss
flow works fine — no formal RFC process.

1. Fork the project at <https://codeberg.org/anuna/imago>
2. Create your feature branch (`git checkout -b feat/your-feature`)
3. Make sure `bash bin/run-tests.sh all` is green before opening a PR
4. Commit your changes (`git commit -m 'feat: …'`)
5. Push to the branch and open a pull request

The core LOC budget gate at 3300 lines is in `.github/workflows/ci.yml`.
It excludes identities, self-modification, examples, tests, and opt-in
plugins. Crossing the soft gate requires a review of the added complexity.

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- LICENSE -->
## License

Distributed under the Apache-2.0 License. See [`LICENSE`](./LICENSE) for
more information.

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- CONTACT -->
## Contact

Project Link: <https://codeberg.org/anuna/imago>

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- ACKNOWLEDGMENTS -->
## Acknowledgments

* [SBCL][sbcl-url] — the runtime that makes image-as-artifact + live redefinition real
* [websocket-driver][wsd-url] — clean WS protocol implementation, server + client
* [dexador][dex-url] — HTTP+SSE used by the Anthropic provider
* [com.inuoe.jzon][jzon-url] — fast, modern JSON for CL
* [ironclad][ironclad-url] — Ed25519 sign/verify behind the did:key identity layer
* [cbcl-rs][cbcl-url] — Rust parser binding, inherits Lean-verified oracle parity
* [`hence`](https://codeberg.org/anuna/hence) — the defeasible-logic task planner that drives [`plan.spl`](./plan.spl)
* [`elephant`](https://elephant.anuna.io/) — signed theory coordination for the SPEC-014 task and evidence graph
* [HarnessDev](https://arxiv.org/abs/2609.01437) — evidence model behind the optional harness evolution control plane
* [Best-README-Template](https://github.com/othneildrew/Best-README-Template) — the structural template this README follows

The bitter-lesson stance owes its framing to recent critiques of agent
frameworks; the "amputable substrate" framing is from anuna's prior
architectural work on operational scaffolding versus capability
augmentation.

Further reading, in roughly the order you'd want to read them:

* [`architecture/ADR-001-image-runtime.md`](./architecture/ADR-001-image-runtime.md) — why SBCL specifically
* [`architecture/ADR-002-identity.md`](./architecture/ADR-002-identity.md) — why did:key for agent identity (and what's deferred)
* [`architecture/CHECKING.md`](./architecture/CHECKING.md) — what `:clean t` actually does at save time
* [`plan.spl`](./plan.spl) — SPEC-011 implementation plan as defeasible-logic rules; query with `hence plan board plan.spl`
* [`test/m4-tests.lisp`](./test/m4-tests.lisp) — the most readable end-to-end exercise of the runtime
* [`test/m7-wss-tests.lisp`](./test/m7-wss-tests.lisp) — gateway round-trip over a real WebSocket on loopback
* [`specs/SPEC-012-self-modification-port.md`](./specs/SPEC-012-self-modification-port.md) — agent self-modification port spec
* [`architecture/ADR-012-self-mod-adversarial-review.md`](./architecture/ADR-012-self-mod-adversarial-review.md) — 11 bypass shapes the spec floor missed, and the IMPL+ amendments that close them
* [`architecture/ADR-013-self-mod-oq-decisions.md`](./architecture/ADR-013-self-mod-oq-decisions.md) — OQ-001..004 resolutions (timeout, packages, printer bounds, defun rollback)
* [`architecture/EXPERIMENT-LOG.md`](./architecture/EXPERIMENT-LOG.md) — six goal-driven runs that shaped SPEC-012, with each finding mapped to the commit that fixed it
* [`plan.spec-012.spl`](./plan.spec-012.spl) — SPEC-012 implementation plan
* [`test/m12-tests.lisp`](./test/m12-tests.lisp) — 22 test functions exercising the safety stack and recursion-safety properties
* [`specs/SPEC-014-harness-evolution-control-plane.md`](./specs/SPEC-014-harness-evolution-control-plane.md) — frozen-candidate and promotion contracts
* [`plan.spec-014.spl`](./plan.spec-014.spl) — Elephant task graph and completion gates for SPEC-014
* [`plugins/evolution/test.lisp`](./plugins/evolution/test.lisp) — evolution control-plane contract and attack suite

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- MARKDOWN LINKS & IMAGES -->
[license-shield]:   https://img.shields.io/badge/License-Apache_2.0-blue.svg?style=for-the-badge
[license-url]:      https://www.apache.org/licenses/LICENSE-2.0
[cl-shield]:        https://img.shields.io/badge/Common_Lisp-ANSI-purple.svg?style=for-the-badge
[cl-url]:           https://common-lisp.net/
[sbcl-shield]:      https://img.shields.io/badge/SBCL-2.6%2B-darkgreen.svg?style=for-the-badge
[sbcl-url]:         https://www.sbcl.org/
[tests-shield]:     https://img.shields.io/badge/tests-19_targets-success.svg?style=for-the-badge
[tests-url]:        ./test/
[loc-shield]:       https://img.shields.io/badge/src_top--level_LOC-4338-informational.svg?style=for-the-badge
[loc-url]:          ./src/

[sbcl-tile]:        https://img.shields.io/badge/SBCL-image_runtime-darkgreen?style=flat-square
[wsd-tile]:         https://img.shields.io/badge/websocket--driver-WS_protocol-orange?style=flat-square
[wsd-url]:          https://github.com/fukamachi/websocket-driver
[dex-tile]:         https://img.shields.io/badge/dexador-HTTP%2BSSE-blue?style=flat-square
[dex-url]:          https://github.com/fukamachi/dexador
[jzon-tile]:        https://img.shields.io/badge/com.inuoe.jzon-JSON-yellow?style=flat-square
[jzon-url]:         https://github.com/Zulu-Inuoe/jzon
[cffi-tile]:        https://img.shields.io/badge/CFFI-FFI-red?style=flat-square
[cffi-url]:         https://cffi.common-lisp.dev/
[ironclad-tile]:    https://img.shields.io/badge/ironclad-Ed25519-purple?style=flat-square
[ironclad-url]:     https://github.com/sharplispers/ironclad
[cbcl-tile]:        https://img.shields.io/badge/cbcl--rs-Lean_verified-darkgreen?style=flat-square
[cbcl-url]:         https://codeberg.org/anuna/cbcl-rs

[status-shield]:    https://img.shields.io/badge/status-experimental-orange.svg?style=for-the-badge
[status-url]:       #about-the-project
