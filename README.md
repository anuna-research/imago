<a id="readme-top"></a>

<!-- PROJECT SHIELDS -->
[![Apache 2.0 License][license-shield]][license-url]
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
    <a href="https://codeberg.org/anuna/anuna-code/src/branch/main/spec/SPEC-011-image-harness.md"><strong>Read the spec »</strong></a>
    <br />
    <br />
    <a href="#try-it">Try it</a>
    ·
    <a href="#built-in-tools">Built-in tools</a>
    ·
    <a href="#roadmap">Roadmap</a>
    ·
    <a href="https://codeberg.org/anuna/anuna-imago/issues">Report a bug</a>
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
        <li><a href="#mental-model">Mental model</a></li>
        <li><a href="#built-in-tools">Built-in tools</a></li>
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

This is the working implementation of [SPEC-011][spec-url], constrained
to roughly 2000 lines of Common Lisp. The runtime is supervised processes.
The wire is CBCL. The substrate is fully redefinable in flight.

<p align="right">(<a href="#readme-top">back to top</a>)</p>


### Built With

* [![SBCL][sbcl-tile]][sbcl-url]
* [![websocket-driver][wsd-tile]][wsd-url]
* [![dexador][dex-tile]][dex-url]
* [![com.inuoe.jzon][jzon-tile]][jzon-url]
* [![CFFI][cffi-tile]][cffi-url]
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
git clone https://codeberg.org/anuna/anuna-imago
cd anuna-imago
bash bin/run-tests.sh all          # 13 suites, 200+ checks, ~30s
bash bin/build-echo-image.sh       # produces ./echo-agent (~57 MB)
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

Five seams to know about:

* **Methods** are `defmethod` — redefine at the REPL, the next call uses
  the new version.
* **Hooks** at `:on-user-input`, `:on-tool-call`, `:on-tool-result`,
  `:on-turn-complete`, `:on-agent-spawn`, `:on-agent-crash`. First
  handler to return `:veto` aborts the chain.
* **Providers** are CLOS classes implementing `provider-stream!`. Stubs
  for tests, Anthropic in production; Bedrock and Vertex are drop-in.
* **Transports** are abstract — `wss-transport` for production, an
  in-memory `mock-transport` for tests.
* **Reasoner** integration is IPC-only. At `:on-tool-call` the harness
  asks a Spindle defeasible-logic theory whether the call is
  `(forbidden …)`; a +Δ or +∂ verdict vetoes before the handler runs.

<p align="right">(<a href="#readme-top">back to top</a>)</p>


### Built-in tools

Five tools auto-register when `imago` loads. They cover introspection on
the harness itself — useful both for an agent that wants to discover its
own surface and for a human debugging a deployed binary. Agents that
don't list them in `:tools` don't expose them to the LLM, so registration
is harmless.

| Name | Returns |
|---|---|
| `harness-list-tools` | All registered tool names |
| `harness-describe-tool` | `{description, permission, schema}` for a name |
| `harness-list-hooks` | Hook keys + handler counts |
| `harness-version` | Harness version string |
| `harness-now` | Current UTC time, ISO-8601 |

```lisp
;; Wire all of them into an agent:
(make-instance 'agent ... :tools *builtin-tool-names*)
```

What's deliberately **not** built in: file IO, shell exec, HTTP fetch,
web search. Those are the "agent framework" abstractions SPEC-011's
bitter-lesson stance refused — they age badly as model capability
climbs, and they're better served by MCP servers or per-project tool
modules. Two opt-in trapdoors (`harness-eval` and `harness-redefine-method`)
for self-modification will live in `examples/self-modifying.lisp` so the
author has to consciously enable them.

<p align="right">(<a href="#readme-top">back to top</a>)</p>


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

`./my-agent` is now a self-contained 56 MB binary you can `scp` to any
machine without SBCL installed. `:clean t` (default) flushes credentials,
async pools, and open log handles before the save — see
[`architecture/CHECKING.md`](./architecture/CHECKING.md) for the
checklist.

To make the agent reachable from a CBCL router, build a `gateway` over
a `wss-transport`:

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
│   │
│   └── providers/
│       ├── stub.lisp                 canned-response provider for tests
│       └── anthropic.lisp            Messages API + mockable HTTP
│
├── test/                             one suite per milestone (M1–M11)
│                                     plus M7-WSS and built-in tools
├── examples/echo.lisp                reference echo agent
├── architecture/
│   ├── ADR-001-image-runtime.md      why SBCL (not ECL)
│   ├── ADR-002-identity.md           why did:key (not did:web/plc)
│   └── CHECKING.md                   :clean t audit checklist
├── plan.spl                          implementation plan (hence)
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

### Image distribution

```lisp
(save-image! path &key toplevel clean executable)  ; DOES NOT RETURN
(pre-save-clean!)                                ; manually trigger checklist
*clean-checklist*  ; :close-receipt-log :shutdown-hook-async-pool
                   ; :drop-credentials :force-gc
(register-credential-eraser! thunk)
*boot-time*                                      ; universal-time at load
*version*                                        ; "0.1.0"
(agent-main)                                     ; toplevel for saved images
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
- [x] Built-in introspection tools
- [ ] Streaming SSE for the Anthropic provider
- [ ] CI matrix M6 step (cbcl-rs cdylib build)
- [ ] `examples/self-modifying.lisp` (`harness-eval` opt-in)
- [ ] Bedrock provider driver
- [ ] Vertex provider driver

By the numbers: **2928 LOC** harness, **~2900 LOC** tests, **63 MB** image
(full-agent profile incl. provider + WSS + identity), **165 ms** p90 cold
start, **17 test suites** × **290+ checks**, all green.

See the [open issues](https://codeberg.org/anuna/anuna-imago/issues) for
proposed features and known issues.

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- CONTRIBUTING -->
## Contributing

Contributions are welcome. The project is small enough that a PR-and-discuss
flow works fine — no formal RFC process.

1. Fork the project at <https://codeberg.org/anuna/anuna-imago>
2. Create your feature branch (`git checkout -b feat/your-feature`)
3. Make sure `bash bin/run-tests.sh all` is green before opening a PR
4. Commit your changes (`git commit -m 'feat: …'`)
5. Push to the branch and open a pull request

The LOC budget gate at 2500 lines (in `.github/workflows/ci.yml`) is a
soft signal — going over warrants a discussion of whether the addition
is paying for itself.

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- LICENSE -->
## License

Distributed under the Apache-2.0 License. See [`LICENSE`](./LICENSE) for
more information.

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- CONTACT -->
## Contact

Hugo O'Connor — hugo.oconnor@gmail.com

Project Link: <https://codeberg.org/anuna/anuna-imago>

Spec: <https://codeberg.org/anuna/anuna-code/src/branch/main/spec/SPEC-011-image-harness.md>

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- ACKNOWLEDGMENTS -->
## Acknowledgments

* [SPEC-011][spec-url] — the original specification this implementation derives from
* [SBCL][sbcl-url] — the runtime that makes image-as-artifact + live redefinition real
* [websocket-driver][wsd-url] — clean WS protocol implementation, server + client
* [dexador][dex-url] — HTTP+SSE used by the Anthropic provider
* [com.inuoe.jzon][jzon-url] — fast, modern JSON for CL
* [cbcl-rs][cbcl-url] — Rust parser binding, inherits Lean-verified oracle parity
* [`hence`](https://codeberg.org/anuna/hence) — the defeasible-logic task planner that drives [`plan.spl`](./plan.spl)
* [Best-README-Template](https://github.com/othneildrew/Best-README-Template) — the structural template this README follows

The bitter-lesson stance owes its framing to recent critiques of agent
frameworks; the "amputable substrate" framing is from anuna's prior
architectural work on operational scaffolding versus capability
augmentation.

Further reading, in roughly the order you'd want to read them:

* [`architecture/ADR-001-image-runtime.md`](./architecture/ADR-001-image-runtime.md) — why SBCL specifically
* [`architecture/ADR-002-identity.md`](./architecture/ADR-002-identity.md) — why did:key for agent identity (and what's deferred)
* [`architecture/CHECKING.md`](./architecture/CHECKING.md) — what `:clean t` actually does at save time
* [`plan.spl`](./plan.spl) — implementation plan as defeasible-logic rules; query with `hence plan board plan.spl`
* [`test/m4-tests.lisp`](./test/m4-tests.lisp) — the most readable end-to-end exercise of the runtime
* [`test/m7-wss-tests.lisp`](./test/m7-wss-tests.lisp) — gateway round-trip over a real WebSocket on loopback

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- MARKDOWN LINKS & IMAGES -->
[license-shield]:   https://img.shields.io/badge/License-Apache_2.0-blue.svg?style=for-the-badge
[license-url]:      https://www.apache.org/licenses/LICENSE-2.0
[cl-shield]:        https://img.shields.io/badge/Common_Lisp-ANSI-purple.svg?style=for-the-badge
[cl-url]:           https://common-lisp.net/
[sbcl-shield]:      https://img.shields.io/badge/SBCL-2.6%2B-darkgreen.svg?style=for-the-badge
[sbcl-url]:         https://www.sbcl.org/
[tests-shield]:     https://img.shields.io/badge/tests-17_suites_green-success.svg?style=for-the-badge
[tests-url]:        ./test/
[loc-shield]:       https://img.shields.io/badge/LOC-2928-informational.svg?style=for-the-badge
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
[cbcl-tile]:        https://img.shields.io/badge/cbcl--rs-Lean_verified-darkgreen?style=flat-square
[cbcl-url]:         https://codeberg.org/anuna/cbcl-rs

[spec-url]:         https://codeberg.org/anuna/anuna-code/src/branch/main/spec/SPEC-011-image-harness.md
