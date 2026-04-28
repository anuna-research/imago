# Initial-agent scaffolder — design

**Status:** draft, awaiting implementation plan
**Date:** 2026-04-28
**Author:** brainstormed with Hugo

## Problem

A new user landing on anuna-imago today has three on-ramps, none of which is
quite "starting point":

1. `examples/echo.lisp` — 16 lines, stub provider only, no tools, no CLI
   beyond what `agent-main` provides via the harness.
2. The README's "Build your own agent" section — a copy-pasteable ~30-line
   snippet living in markdown, requiring the reader to assemble the
   surrounding project structure (`.asd`, build script, etc.) themselves.
3. `examples/self-modifying.lisp` — opt-in installer for the SPEC-012 port,
   advanced.

None of these gives a new user a complete, runnable, editable project that
demonstrates the four most-edited surfaces (tools, hooks, agent
construction, toplevel) in one place.

## Goal

Ship a `bin/new-agent.sh` script in the imago repo that scaffolds a
**standalone, vendored, immediately-runnable** project for a new user. After
running it, the new user has a directory they can `cd` into, build, and
extend — with no external setup beyond Quicklisp.

## Non-goals

- A package-manager / Quicklisp distribution of imago. Imago is not on
  Quicklisp; vendoring sidesteps that.
- A web-based scaffolder, GUI, or interactive wizard.
- A multi-agent project layout (`agents/foo/`, `agents/bar/`). YAGNI.
- Provider selection at scaffold time. The starter ships with the stub
  provider and inline comments showing how to swap.
- Auto-syncing the vendored harness with upstream. Vendoring is a one-way
  copy; the README documents the manual update path.

## Stance: vendoring vs. external dependency

The scaffolded project **vendors imago** — copies `imago.asd`, `src/`, and
`theories/` into a subdirectory of the new project rather than referencing
imago as an external ASDF dependency.

This decision aligns with imago's own bitter-lesson stance: the binary IS
the heap, the harness is meant to be redefined in flight. Treating imago as
a frozen external dep is somewhat at odds with that. Vendoring lets the new
user mutate the harness from day one — at the source level, before they
ever load the image — which is exactly the headline use case.

The cost is upstream sync: when imago gets a bug fix, vendored copies don't
see it automatically. The README documents the manual update path
(`rm -rf imago/ && cp -R …`). This is acceptable because (a) the harness is
~4100 LOC and stable, (b) users who care about upstream fixes can script
the update, (c) heap-level forking happens anyway via `harness-eval` and
saved images.

## CLI

```sh
bash bin/new-agent.sh <name> <target-dir> [--force]
```

- `<name>` — used as the package name, the agent's `:id`, the binary name,
  and the `.asd` system name. Validated to match `^[a-z][a-z0-9-]*$` (lowercase,
  alphanumeric + hyphens, starts with a letter).
- `<target-dir>` — created if it doesn't exist; if it exists and is
  non-empty, the script aborts unless `--force` is passed.
- The script refuses to scaffold into a directory inside the imago tree
  itself, to prevent accidental nesting.
- On success, prints a 4-line "next steps" hint:

  ```
  ✓ Scaffolded my-agent at ../my-agent
    cd ../my-agent
    bash bin/build.sh        # ~30s, produces ./my-agent
    ./my-agent --echo "hi"
  ```

## Generated tree

```
my-agent/
├── my-agent.asd            ; defsystem #:my-agent, :depends-on (#:imago)
├── imago/                  ; vendored at scaffold time
│   ├── imago.asd
│   ├── src/                ; full harness, ~4100 LOC
│   └── theories/
│       └── self-modification-floor.spl
├── src/
│   └── agent.lisp          ; demonstrative starter (see below)
├── bin/
│   ├── build.sh            ; sbcl + ASDF + save-image! → ./my-agent
│   └── run-tests.sh        ; loads test/smoke.lisp, calls (run-smoke)
├── test/
│   └── smoke.lisp          ; ~25-line smoke test, no test-framework dep
├── README.md               ; one-screen orientation
├── LICENSE                 ; placeholder line "TODO: choose a license"
└── .gitignore              ; *.fasl, /<name> binary, .DS_Store
```

### Vendoring scope

The scaffolder copies exactly:

- `imago.asd` (top-level system definition)
- `src/` (full harness)
- `theories/self-modification-floor.spl` (one tiny file; needed if the user
  later opts into the SPEC-012 port)

**Not vendored:** `plugins/`, `examples/`, `test/`, `architecture/`,
`specs/`, `bin/`, `plan.spl`, `plan.spec-012.spl`, `LICENSE`, `README.md`.
Plugins and the OpenRouter/Z.ai drivers can be copied in manually if the
user wants them later. ADRs and specs are upstream documentation, not
project artifacts.

### Templating

Three identifiers are stamped at scaffold time:

| Placeholder | Stamped to (for `<name> = my-agent`) |
|---|---|
| `<NAME>` | `my-agent` (used in defpackage, asdf system name, binary name, gitignore) |
| `<NAME-SYM>` | `my-agent` (CL symbol; same casing as `<NAME>`) |
| `<NAME-CAP>` | `"my-agent:reply"` (the agent's capability string) |

All other content is literal.

## File contents

### `my-agent.asd`

```lisp
(defsystem #:<NAME>
  :name "<NAME>"
  :description "An agent built on anuna-imago."
  :version "0.1.0"
  :license "TODO"
  :depends-on (#:imago)
  :components ((:module "src"
                :components ((:file "agent")))))
```

A `defpackage` for `#:<NAME>` lives at the top of `src/agent.lisp` rather
than in a separate `packages.lisp` — keeping the new user's project to a
single source file until they outgrow it.

### `src/agent.lisp` — the demonstrative starter

```lisp
;;;; src/agent.lisp — your agent.
;;;;
;;;; Four sections below show the surfaces you'll most often edit:
;;;;   1. Tools        — what the LLM can call
;;;;   2. Hooks        — what runs around each turn
;;;;   3. The agent    — provider, prompt, identity, capability
;;;;   4. Toplevel     — what `./<NAME>` does when launched
;;;;
;;;; Run `./<NAME> --echo "hello"` after building. Then come back here
;;;; and start changing things — the harness picks up redefinitions live.

(defpackage #:<NAME>
  (:use #:cl)
  (:export #:toplevel))

(in-package #:<NAME>)

;;; ---------------------------------------------------------------- 1. Tools
;;; Tools are functions the LLM can call. `define-tool` registers them
;;; globally; the agent's `:tools` slot lists which ones it actually
;;; exposes. See imago/src/tools.lisp for the full surface.

(anuna-imago:define-tool greet
  :description "Greet someone by name."
  :schema      ((:name :type :string :required-p t :description "Person to greet"))
  :handler     (lambda (args) (format nil "Hello, ~A." (getf args :name))))

;; Add more tools here. Built-ins (harness-list-tools, harness-now, etc.)
;; auto-register when imago loads — list them in :tools to expose them.


;;; ---------------------------------------------------------------- 2. Hooks
;;; Hooks fire around the turn loop. First handler to return :veto aborts
;;; the chain. Uncomment to log every tool call this agent makes.

;; (anuna-imago:register-hook :on-tool-call
;;   (lambda (agent tool-name args)
;;     (declare (ignore agent))
;;     (format t "~&[tool] ~A ~S~%" tool-name args)
;;     nil))                                          ; nil = don't veto


;;; -------------------------------------------------------------- 3. The agent
;;; Swap `make-stub-provider` for `make-anthropic-provider` (or one of
;;; the plugins under imago/plugins/) once you have an API key.

(defun build-agent ()
  (make-instance 'anuna-imago:agent
                 :id            '<NAME-SYM>
                 :capability    <NAME-CAP>
                 :provider      (anuna-imago:make-stub-provider)
                 :system-prompt "You are <NAME>. Be concise."
                 :tools         (cons 'greet anuna-imago:*builtin-tool-names*)))


;;; --------------------------------------------------------------- 4. Toplevel
;;; What runs when `./<NAME>` launches. Keep this thin — agent logic
;;; belongs in tools and hooks, not here.

(defun toplevel ()
  (let* ((sup   (anuna-imago:make-supervisor 'my-sup))
         (agent (build-agent)))
    (anuna-imago:spawn-agent! sup agent)
    (sleep 0.05)
    (anuna-imago:agent-main)))     ; reuses harness --echo / --serve / --version
```

### `bin/build.sh`

```sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Locate quicklisp setup (covers the two common install locations).
QL_SETUP="${HOME}/quicklisp/setup.lisp"
[[ -f "$QL_SETUP" ]] || QL_SETUP="${HOME}/.quicklisp/setup.lisp"
[[ -f "$QL_SETUP" ]] || { echo "quicklisp not found; install it first"; exit 1; }

sbcl --no-userinit --no-sysinit --non-interactive \
     --load "$QL_SETUP" \
     --eval "(push (truename \"./\")       asdf:*central-registry*)" \
     --eval "(push (truename \"./imago/\") asdf:*central-registry*)" \
     --eval "(asdf:load-system :<NAME>)" \
     --eval "(anuna-imago:save-image! \"<NAME>\"
                                       :toplevel '<NAME-SYM>::toplevel
                                       :executable t)"
```

### `test/smoke.lisp`

```lisp
;;;; test/smoke.lisp — minimal smoke test
;;;; Asserts the agent can be built, spawned, asked, and drained.
;;;; Extend this with real assertions as your agent grows behaviour.

(in-package #:<NAME>)

(defun run-smoke ()
  (let* ((sup   (anuna-imago:make-supervisor 'smoke-sup))
         (agent (build-agent)))
    (anuna-imago:spawn-agent! sup agent)
    (sleep 0.05)
    (let ((reply (anuna-imago:ask-agent agent "ping")))
      (assert (getf reply :text) ()
              "Expected a non-empty :text in reply, got ~S" reply)
      (format t "~&✓ smoke: agent replied ~S~%" (getf reply :text)))
    (anuna-imago:send! (anuna-imago:agent-mailbox agent) :shutdown)
    (sleep 0.05)
    (anuna-imago:drain-supervisor! sup)
    :ok))
```

### `bin/run-tests.sh`

Same shell shape as `build.sh`. Pushes both `./` and `./imago/` onto
`asdf:*central-registry*`, loads the project's system with
`(asdf:load-system :<NAME>)` (so `#:<NAME>` package exists), then
`(load "test/smoke.lisp")` and `(<NAME>::run-smoke)`. Exits non-zero on
assertion failure. ~25 lines.

### `README.md`

```markdown
# <NAME>

An agent built on [anuna-imago](./imago/), vendored at scaffold time.

## Build and run

    bash bin/build.sh                    # ~30s
    ./<NAME> --echo "hello"
    ./<NAME> --serve 60                  # serve for 60s, drain on SIGTERM

## What's in here

| Path | What |
|---|---|
| `src/agent.lisp`   | Your agent. Tools, hooks, provider, prompt — start here. |
| `imago/`           | Vendored harness. Edit freely; you own this copy. |
| `test/smoke.lisp`  | Smoke test. `bash bin/run-tests.sh` |
| `bin/build.sh`     | Builds the binary via `save-image!`. |

## Next steps

1. Edit `src/agent.lisp` — change the system prompt, add a tool.
2. Swap `make-stub-provider` for a real one. See `imago/README.md`
   "Build your own agent" for Anthropic, OpenRouter, and Z.ai examples.
3. Add identity (`generate-identity`) if you'll connect to a router.
4. Read `imago/architecture/CHECKING.md` before saving images with
   secrets in scope.

## Updating the vendored harness

Vendored is vendored — upstream fixes don't flow in automatically. To pull
a newer imago:

    rm -rf imago/
    cp -R /path/to/anuna-imago/{imago.asd,src,theories} imago/

Or re-run `bin/new-agent.sh` against an empty directory and diff.
```

### `.gitignore`

```
*.fasl
.DS_Store
/<NAME>
```

(The leading slash anchors `<NAME>` to the project root, so a directory
named `<NAME>` deeper in the tree wouldn't be accidentally ignored.)

### `LICENSE`

```
TODO: choose a license. See https://choosealicense.com/.
```

## Acceptance criteria

A scaffolded project meets all of:

1. `bash bin/new-agent.sh test-agent /tmp/test-agent` exits 0 in under 5
   seconds (vendoring `cp -R` dominates the runtime).
2. `cd /tmp/test-agent && bash bin/build.sh` produces `/tmp/test-agent/test-agent`,
   exits 0.
3. `./test-agent --version` prints `anuna-imago 0.1.0` (or whatever the
   vendored version is).
4. `./test-agent --echo "hello"` prints a non-empty reply (the stub
   provider's canned response).
5. `bash bin/run-tests.sh` exits 0 and the smoke test asserts pass.
6. `git init && git add . && git status` shows only the scaffolded files,
   not `*.fasl` or the built binary.
7. The scaffolder rejects a non-empty target dir without `--force`.
8. The scaffolder rejects an invalid name (e.g. `My_Agent`, `123agent`,
   `agent name`) with a clear error.
9. The scaffolder rejects scaffolding into a directory inside the imago
   tree (e.g. `bash bin/new-agent.sh foo ./examples/foo`).

## Open questions / explicit deferrals

- **Provider selection at scaffold time** (`--provider anthropic`, etc.) —
  deferred. Users edit one line.
- **Multi-agent project layout** — deferred. Users can manually add more
  `src/*.lisp` files and update the `.asd` `:components`.
- **Identity / gateway stubs in the starter** — deferred. They live in the
  README's "next steps" rather than as commented-out code in `agent.lisp`,
  to keep the starter readable.
- **Auto-detection of imago version at vendor time** — the scaffolder just
  copies whatever's in the imago tree it's running from. No version pin
  recorded. If we want a `imago/VERSION.txt` stamp later, easy addition.
- **A `bin/update-imago.sh` helper in the scaffolded project** — deferred;
  the README's `rm -rf && cp -R` is enough for v1. Could be added once
  several users hit the upgrade path.

## Implementation notes

- `bin/new-agent.sh` is plain bash; no Lisp at scaffold time. Simpler to
  audit and faster to run.
- File templates live as heredocs inside the script for v1. If they grow
  past ~200 lines combined, split into a `bin/templates/` directory.
- Self-test: a `bin/test-scaffolder.sh` (in imago, not in the scaffolded
  project) invokes `new-agent.sh` against a tmp dir, runs the scaffolded
  project's `bin/build.sh` and `bin/run-tests.sh`, asserts the binary
  runs. This is what closes the loop on acceptance criterion #1–#5.
