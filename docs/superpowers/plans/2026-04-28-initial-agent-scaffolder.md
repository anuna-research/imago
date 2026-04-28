# Initial-agent scaffolder — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `bin/new-agent.sh` — a bash scaffolder that creates a standalone, vendored, immediately-runnable anuna-imago agent project for a new user — plus `bin/test-scaffolder.sh` which exercises the full pipeline (scaffold → build → run smoke test) end-to-end.

**Architecture:** The scaffolder is plain bash with file templates inlined as heredocs. It validates a name (`^[a-z][a-z0-9-]*$`) and target directory, refuses to scaffold into the imago tree itself, copies imago's `imago.asd + src/ + theories/` into a `imago/` subdirectory of the target (vendoring), then writes a small set of templated and static files. The self-test runs the scaffolder against a tmp dir and asserts each acceptance criterion in order, including building the resulting binary and running its smoke test (criteria #1–#9 from the spec).

**Tech Stack:** Bash (target macOS / Linux, set `-euo pipefail`), SBCL 2.6+, ASDF, Quicklisp. Both new scripts are POSIX-friendly bash; templates use `cat <<EOF` heredocs with `${var}` substitution.

**Spec:** [`docs/superpowers/specs/2026-04-28-initial-agent-scaffolder-design.md`](../specs/2026-04-28-initial-agent-scaffolder-design.md) (committed as `5896a58`).

---

## File structure

| Path | Status | Responsibility |
|---|---|---|
| `bin/new-agent.sh` | new | The scaffolder. Validates args, vendors imago, emits templated files. |
| `bin/test-scaffolder.sh` | new | End-to-end self-test of the scaffolder. Asserts spec acceptance criteria #1–#9. |

No existing files are modified. Generated files (created at scaffold time, not committed in this plan) are listed in the spec.

---

## Task 1: Test-harness skeleton + name validation + minimal scaffolder

**Files:**
- Create: `bin/test-scaffolder.sh`
- Create: `bin/new-agent.sh`

- [ ] **Step 1: Write the failing test harness**

Create `bin/test-scaffolder.sh` with the following content:

```bash
#!/usr/bin/env bash
# bin/test-scaffolder.sh — end-to-end self-test for bin/new-agent.sh.
# Asserts the spec's acceptance criteria. Cleans up its tmp dir on exit.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCAFFOLDER="$REPO_ROOT/bin/new-agent.sh"

TMP_ROOT="$(mktemp -d -t imago-scaffolder-test.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

# expect_success <description> <command...>
expect_success() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  ✓ $desc"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $desc — command failed: $*"
    FAIL=$((FAIL + 1))
  fi
}

# expect_failure <description> <command...>
expect_failure() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  ✗ $desc — expected failure, but succeeded: $*"
    FAIL=$((FAIL + 1))
  else
    echo "  ✓ $desc"
    PASS=$((PASS + 1))
  fi
}

# ---------------------------------------------------------------------------
echo "# arg validation"
expect_failure "no args → exits non-zero"            bash "$SCAFFOLDER"
expect_failure "one arg → exits non-zero"            bash "$SCAFFOLDER" foo
expect_failure "invalid name (uppercase)"            bash "$SCAFFOLDER" My_Agent "$TMP_ROOT/upper"
expect_failure "invalid name (starts with digit)"    bash "$SCAFFOLDER" 123agent "$TMP_ROOT/digit"
expect_failure "invalid name (contains space)"       bash "$SCAFFOLDER" "my agent" "$TMP_ROOT/space"

# ---------------------------------------------------------------------------
echo "# basic happy path: target dir is created"
TARGET="$TMP_ROOT/test-agent"
expect_success "scaffolder runs"                     bash "$SCAFFOLDER" test-agent "$TARGET"
expect_success "target dir exists"                   test -d "$TARGET"

# ---------------------------------------------------------------------------
echo
echo "result: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x bin/test-scaffolder.sh
```

- [ ] **Step 3: Run the test — verify it fails (scaffolder doesn't exist yet)**

```bash
bash bin/test-scaffolder.sh
```

Expected: every assertion fails because `bin/new-agent.sh` doesn't exist. The script itself exits non-zero.

- [ ] **Step 4: Write the minimal scaffolder**

Create `bin/new-agent.sh`:

```bash
#!/usr/bin/env bash
# bin/new-agent.sh — scaffold a standalone anuna-imago agent project.
# Usage: bin/new-agent.sh <name> <target-dir> [--force]
set -euo pipefail

usage() {
  cat >&2 <<USAGE
Usage: bin/new-agent.sh <name> <target-dir> [--force]

  <name>        agent name; must match ^[a-z][a-z0-9-]*$
  <target-dir>  must not be a non-empty existing dir, unless --force is given;
                must not be inside the imago tree itself.

Example:
  bash bin/new-agent.sh my-agent ../my-agent
USAGE
  exit 2
}

[[ $# -ge 2 ]] || usage

NAME="$1"
TARGET="$2"
FORCE=0
shift 2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1 ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
  shift
done

# Validate name.
if [[ ! "$NAME" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "Invalid <name>: $NAME (must match ^[a-z][a-z0-9-]*\$)" >&2
  exit 2
fi

# Create target dir.
mkdir -p "$TARGET"
TARGET_ABS="$(cd "$TARGET" && pwd)"

echo "✓ Scaffolded $NAME at $TARGET"
```

- [ ] **Step 5: Make it executable**

```bash
chmod +x bin/new-agent.sh
```

- [ ] **Step 6: Run the test — verify it passes**

```bash
bash bin/test-scaffolder.sh
```

Expected: all 7 assertions pass; script exits 0.

- [ ] **Step 7: Commit**

```bash
git add bin/new-agent.sh bin/test-scaffolder.sh
git commit -m "$(cat <<'EOF'
feat(scaffolder): bootstrap new-agent.sh + test harness

bin/new-agent.sh validates <name> against ^[a-z][a-z0-9-]*$ and
creates the target directory. bin/test-scaffolder.sh asserts arg
validation and dir creation; will grow as the scaffolder fills out.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Refuse scaffolding into the imago tree

**Files:**
- Modify: `bin/test-scaffolder.sh` (add assertions)
- Modify: `bin/new-agent.sh` (add nesting check)

- [ ] **Step 1: Add the failing test**

Append to `bin/test-scaffolder.sh` after the "basic happy path" block, before the result summary:

```bash
# ---------------------------------------------------------------------------
echo "# nesting refusal"
expect_failure "refuses target inside imago tree"    bash "$SCAFFOLDER" foo "$REPO_ROOT/examples/foo"
expect_failure "refuses target = imago tree itself"  bash "$SCAFFOLDER" foo "$REPO_ROOT"
```

- [ ] **Step 2: Run the test — verify the new assertions fail**

```bash
bash bin/test-scaffolder.sh
```

Expected: 2 new failures (current scaffolder happily creates dirs anywhere).

- [ ] **Step 3: Add the nesting check to the scaffolder**

In `bin/new-agent.sh`, add immediately before `mkdir -p "$TARGET"`:

```bash
# Refuse to scaffold inside the imago tree itself.
IMAGO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TARGET_PARENT_ABS="$(cd "$(dirname "$TARGET")" && pwd -P)"
TARGET_PROBE="$TARGET_PARENT_ABS/$(basename "$TARGET")"
case "$TARGET_PROBE/" in
  "$IMAGO_ROOT"/*|"$IMAGO_ROOT/")
    echo "Refusing to scaffold into the imago tree: $TARGET" >&2
    exit 2
    ;;
esac
```

(Placing the check before `mkdir` so we don't leave a stub dir behind on rejection.)

- [ ] **Step 4: Run the test — verify all assertions pass**

```bash
bash bin/test-scaffolder.sh
```

Expected: all 9 assertions pass.

- [ ] **Step 5: Commit**

```bash
git add bin/new-agent.sh bin/test-scaffolder.sh
git commit -m "$(cat <<'EOF'
feat(scaffolder): refuse target inside imago tree

Compares the resolved target path against the resolved imago root and
exits 2 if the target is the imago tree or any directory beneath it.
Prevents accidental nesting that would shadow imago's own files.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Refuse non-empty target without --force

**Files:**
- Modify: `bin/test-scaffolder.sh`
- Modify: `bin/new-agent.sh`

- [ ] **Step 1: Add the failing test**

Append to `bin/test-scaffolder.sh` before the result summary:

```bash
# ---------------------------------------------------------------------------
echo "# non-empty target rejection"
NONEMPTY="$TMP_ROOT/nonempty"
mkdir -p "$NONEMPTY"
touch "$NONEMPTY/preexisting.txt"
expect_failure "non-empty target without --force"    bash "$SCAFFOLDER" foo "$NONEMPTY"
expect_success "non-empty target WITH --force"       bash "$SCAFFOLDER" foo "$NONEMPTY" --force
```

- [ ] **Step 2: Run the test — verify the new "without --force" assertion fails**

```bash
bash bin/test-scaffolder.sh
```

Expected: 1 new failure ("non-empty target without --force" — current scaffolder accepts it).

- [ ] **Step 3: Add the non-empty check**

In `bin/new-agent.sh`, after the nesting check and before `mkdir -p "$TARGET"`, add:

```bash
# Refuse non-empty existing target unless --force was passed.
if [[ -d "$TARGET" ]] && [[ -n "$(ls -A "$TARGET" 2>/dev/null)" ]] && [[ "$FORCE" -eq 0 ]]; then
  echo "Target dir is non-empty: $TARGET (pass --force to scaffold anyway)" >&2
  exit 2
fi
```

- [ ] **Step 4: Run the test — verify all assertions pass**

```bash
bash bin/test-scaffolder.sh
```

Expected: all 11 assertions pass.

- [ ] **Step 5: Commit**

```bash
git add bin/new-agent.sh bin/test-scaffolder.sh
git commit -m "$(cat <<'EOF'
feat(scaffolder): require --force for non-empty target

Aborts with exit 2 if the target dir already contains files unless
--force is passed. Prevents accidental overwrites; --force is the
explicit opt-in for re-scaffolding into an existing tree.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Vendor imago into target/imago/

**Files:**
- Modify: `bin/test-scaffolder.sh`
- Modify: `bin/new-agent.sh`

- [ ] **Step 1: Add the failing test**

Append to `bin/test-scaffolder.sh`, before the result summary:

```bash
# ---------------------------------------------------------------------------
echo "# vendoring"
VENDOR_TARGET="$TMP_ROOT/vendor-test"
expect_success "scaffolds into fresh target"         bash "$SCAFFOLDER" vendor-test "$VENDOR_TARGET"
expect_success "imago.asd vendored"                  test -f "$VENDOR_TARGET/imago/imago.asd"
expect_success "imago/src/ vendored"                 test -d "$VENDOR_TARGET/imago/src"
expect_success "imago/src/packages.lisp vendored"    test -f "$VENDOR_TARGET/imago/src/packages.lisp"
expect_success "imago/theories/ vendored"            test -d "$VENDOR_TARGET/imago/theories"
expect_success "self-modification-floor vendored"    test -f "$VENDOR_TARGET/imago/theories/self-modification-floor.spl"
expect_failure "plugins/ NOT vendored"               test -d "$VENDOR_TARGET/imago/plugins"
expect_failure "test/ NOT vendored"                  test -d "$VENDOR_TARGET/imago/test"
expect_failure "examples/ NOT vendored"              test -d "$VENDOR_TARGET/imago/examples"
```

- [ ] **Step 2: Run the test — verify the new assertions fail**

```bash
bash bin/test-scaffolder.sh
```

Expected: the 6 `expect_success` checks fail because no vendoring happens yet. The 3 `expect_failure` checks pass trivially.

- [ ] **Step 3: Add the vendoring step**

In `bin/new-agent.sh`, after `TARGET_ABS=...`, add:

```bash
# Vendor imago: copy imago.asd, src/, theories/ into TARGET/imago/.
mkdir -p "$TARGET_ABS/imago"
cp    "$IMAGO_ROOT/imago.asd"  "$TARGET_ABS/imago/imago.asd"
cp -R "$IMAGO_ROOT/src"        "$TARGET_ABS/imago/src"
cp -R "$IMAGO_ROOT/theories"   "$TARGET_ABS/imago/theories"
```

- [ ] **Step 4: Run the test — verify all assertions pass**

```bash
bash bin/test-scaffolder.sh
```

Expected: all 20 assertions pass.

- [ ] **Step 5: Commit**

```bash
git add bin/new-agent.sh bin/test-scaffolder.sh
git commit -m "$(cat <<'EOF'
feat(scaffolder): vendor imago.asd, src/, theories/

Copies the harness into <target>/imago/ at scaffold time so the new
project is fully self-contained. Plugins, examples, tests, ADRs, and
specs are deliberately not vendored — they are upstream artifacts the
user can pull in manually if needed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Generate the project's `<NAME>.asd`

**Files:**
- Modify: `bin/test-scaffolder.sh`
- Modify: `bin/new-agent.sh`

- [ ] **Step 1: Add the failing test**

Append to `bin/test-scaffolder.sh`, before the result summary:

```bash
# ---------------------------------------------------------------------------
echo "# .asd generation"
expect_success ".asd file exists"                    test -f "$VENDOR_TARGET/vendor-test.asd"
expect_success ".asd has correct system name"        grep -q '#:vendor-test' "$VENDOR_TARGET/vendor-test.asd"
expect_success ".asd depends on imago"               grep -q ':depends-on (#:imago)' "$VENDOR_TARGET/vendor-test.asd"
```

- [ ] **Step 2: Run the test — verify the new assertions fail**

```bash
bash bin/test-scaffolder.sh
```

Expected: 3 new failures.

- [ ] **Step 3: Add the .asd template**

In `bin/new-agent.sh`, after the vendoring block, add:

```bash
# Generate <name>.asd at the project root.
cat > "$TARGET_ABS/$NAME.asd" <<EOF
(defsystem #:$NAME
  :name "$NAME"
  :description "An agent built on anuna-imago."
  :version "0.1.0"
  :license "TODO"
  :depends-on (#:imago)
  :components ((:module "src"
                :components ((:file "agent")))))
EOF
```

- [ ] **Step 4: Run the test — verify all assertions pass**

```bash
bash bin/test-scaffolder.sh
```

Expected: all 23 assertions pass.

- [ ] **Step 5: Commit**

```bash
git add bin/new-agent.sh bin/test-scaffolder.sh
git commit -m "$(cat <<'EOF'
feat(scaffolder): generate <NAME>.asd at project root

Single-component ASDF system that depends on #:imago (loaded from the
vendored ./imago/ subdir via the build script's central-registry
push) and pulls in src/agent.lisp.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Generate `src/agent.lisp` (demonstrative starter)

**Files:**
- Modify: `bin/test-scaffolder.sh`
- Modify: `bin/new-agent.sh`

- [ ] **Step 1: Add the failing test**

Append to `bin/test-scaffolder.sh`, before the result summary:

```bash
# ---------------------------------------------------------------------------
echo "# src/agent.lisp generation"
expect_success "src/agent.lisp exists"               test -f "$VENDOR_TARGET/src/agent.lisp"
expect_success "defines #:vendor-test package"       grep -q '(defpackage #:vendor-test' "$VENDOR_TARGET/src/agent.lisp"
expect_success "exports toplevel"                    grep -q '#:toplevel' "$VENDOR_TARGET/src/agent.lisp"
expect_success "defines build-agent"                 grep -q '(defun build-agent' "$VENDOR_TARGET/src/agent.lisp"
expect_success "uses stub provider by default"       grep -q 'make-stub-provider' "$VENDOR_TARGET/src/agent.lisp"
expect_success "registers greet tool"                grep -q "define-tool greet" "$VENDOR_TARGET/src/agent.lisp"
expect_success "uses stamped capability"             grep -q '"vendor-test:reply"' "$VENDOR_TARGET/src/agent.lisp"
```

- [ ] **Step 2: Run the test — verify the new assertions fail**

```bash
bash bin/test-scaffolder.sh
```

Expected: 7 new failures.

- [ ] **Step 3: Add the agent.lisp template**

In `bin/new-agent.sh`, after the .asd block, add:

```bash
# Generate src/agent.lisp.
mkdir -p "$TARGET_ABS/src"
cat > "$TARGET_ABS/src/agent.lisp" <<EOF
;;;; src/agent.lisp — your agent.
;;;;
;;;; Four sections below show the surfaces you'll most often edit:
;;;;   1. Tools        — what the LLM can call
;;;;   2. Hooks        — what runs around each turn
;;;;   3. The agent    — provider, prompt, identity, capability
;;;;   4. Toplevel     — what \`./$NAME\` does when launched
;;;;
;;;; Run \`./$NAME --echo "hello"\` after building. Then come back here
;;;; and start changing things — the harness picks up redefinitions live.

(defpackage #:$NAME
  (:use #:cl)
  (:export #:toplevel))

(in-package #:$NAME)

;;; ---------------------------------------------------------------- 1. Tools
;;; Tools are functions the LLM can call. \`define-tool\` registers them
;;; globally; the agent's \`:tools\` slot lists which ones it actually
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
;;; Swap \`make-stub-provider\` for \`make-anthropic-provider\` (or one of
;;; the plugins under imago/plugins/) once you have an API key.

(defun build-agent ()
  (make-instance 'anuna-imago:agent
                 :id            '$NAME
                 :capability    "$NAME:reply"
                 :provider      (anuna-imago:make-stub-provider)
                 :system-prompt "You are $NAME. Be concise."
                 :tools         (cons 'greet anuna-imago:*builtin-tool-names*)))


;;; --------------------------------------------------------------- 4. Toplevel
;;; What runs when \`./$NAME\` launches. Keep this thin — agent logic
;;; belongs in tools and hooks, not here.

(defun toplevel ()
  (let* ((sup   (anuna-imago:make-supervisor 'my-sup))
         (agent (build-agent)))
    (anuna-imago:spawn-agent! sup agent)
    (sleep 0.05)
    (anuna-imago:agent-main)))     ; reuses harness --echo / --serve / --version
EOF
```

(The `\`` escapes around backticks make bash emit literal backticks into the Lisp file. `$NAME` is interpolated everywhere it appears; there are no `\$NAME` escapes since every `$NAME` should be substituted.)

- [ ] **Step 4: Run the test — verify all assertions pass**

```bash
bash bin/test-scaffolder.sh
```

Expected: all 30 assertions pass.

- [ ] **Step 5: Sanity-check the generated file looks right**

```bash
TMP_INSPECT="$(mktemp -d)"
bash bin/new-agent.sh peek "$TMP_INSPECT/peek"
cat "$TMP_INSPECT/peek/src/agent.lisp"
rm -rf "$TMP_INSPECT"
```

Expected: prints the file with `peek` substituted for `$NAME` everywhere it should be (defpackage, defun, capability string, system prompt, comments) and *not* substituted in the literal `:tools` argument lambda.

- [ ] **Step 6: Commit**

```bash
git add bin/new-agent.sh bin/test-scaffolder.sh
git commit -m "$(cat <<'EOF'
feat(scaffolder): generate src/agent.lisp starter

The demonstrative starter wires the four most-edited surfaces — tools,
hooks (commented), agent construction, toplevel — in one ~80-line
file. Stubs the provider so the first build runs without an API key;
exposes the 10 built-in introspection tools alongside one example
custom tool (greet).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Generate `bin/build.sh`

**Files:**
- Modify: `bin/test-scaffolder.sh`
- Modify: `bin/new-agent.sh`

- [ ] **Step 1: Add the failing test**

Append to `bin/test-scaffolder.sh`, before the result summary:

```bash
# ---------------------------------------------------------------------------
echo "# bin/build.sh generation"
expect_success "build.sh exists"                     test -f "$VENDOR_TARGET/bin/build.sh"
expect_success "build.sh is executable"              test -x "$VENDOR_TARGET/bin/build.sh"
expect_success "build.sh loads :vendor-test"         grep -q ':vendor-test' "$VENDOR_TARGET/bin/build.sh"
expect_success "build.sh names binary correctly"     grep -q '"vendor-test"' "$VENDOR_TARGET/bin/build.sh"
expect_success "build.sh saves with toplevel"        grep -q "vendor-test::toplevel" "$VENDOR_TARGET/bin/build.sh"
```

- [ ] **Step 2: Run the test — verify the new assertions fail**

```bash
bash bin/test-scaffolder.sh
```

Expected: 5 new failures.

- [ ] **Step 3: Add the build.sh template**

In `bin/new-agent.sh`, after the agent.lisp block, add:

```bash
# Generate bin/build.sh.
mkdir -p "$TARGET_ABS/bin"
cat > "$TARGET_ABS/bin/build.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "\$(dirname "\$0")/.."

# Locate quicklisp setup (covers the two common install locations).
QL_SETUP="\${HOME}/quicklisp/setup.lisp"
[[ -f "\$QL_SETUP" ]] || QL_SETUP="\${HOME}/.quicklisp/setup.lisp"
[[ -f "\$QL_SETUP" ]] || { echo "quicklisp not found; install it first"; exit 1; }

sbcl --no-userinit --no-sysinit --non-interactive \\
     --load "\$QL_SETUP" \\
     --eval "(push (truename \\"./\\")       asdf:*central-registry*)" \\
     --eval "(push (truename \\"./imago/\\") asdf:*central-registry*)" \\
     --eval "(asdf:load-system :$NAME)" \\
     --eval "(anuna-imago:save-image! \\"$NAME\\"
                                       :toplevel '$NAME::toplevel
                                       :executable t)"
EOF
chmod +x "$TARGET_ABS/bin/build.sh"
```

(All `$VAR` references that should resolve at *build time* — `$HOME`, `$QL_SETUP`, `$0`, `$1` — are escaped as `\$VAR` so they survive the heredoc. Only `$NAME` is interpolated by the scaffolder.)

- [ ] **Step 4: Run the test — verify all assertions pass**

```bash
bash bin/test-scaffolder.sh
```

Expected: all 35 assertions pass.

- [ ] **Step 5: Commit**

```bash
git add bin/new-agent.sh bin/test-scaffolder.sh
git commit -m "$(cat <<'EOF'
feat(scaffolder): generate bin/build.sh

SBCL + ASDF + save-image! pipeline that pushes both the project root
and ./imago/ onto *central-registry*, loads the project's system, and
saves an executable image under the project root with the user's
chosen <name> as the binary filename.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Generate `test/smoke.lisp` and `bin/run-tests.sh`

**Files:**
- Modify: `bin/test-scaffolder.sh`
- Modify: `bin/new-agent.sh`

- [ ] **Step 1: Add the failing test**

Append to `bin/test-scaffolder.sh`, before the result summary:

```bash
# ---------------------------------------------------------------------------
echo "# smoke test + run-tests.sh generation"
expect_success "test/smoke.lisp exists"              test -f "$VENDOR_TARGET/test/smoke.lisp"
expect_success "smoke.lisp uses correct package"     grep -q '(in-package #:vendor-test)' "$VENDOR_TARGET/test/smoke.lisp"
expect_success "smoke.lisp defines run-smoke"        grep -q '(defun run-smoke' "$VENDOR_TARGET/test/smoke.lisp"
expect_success "bin/run-tests.sh exists"             test -f "$VENDOR_TARGET/bin/run-tests.sh"
expect_success "run-tests.sh is executable"          test -x "$VENDOR_TARGET/bin/run-tests.sh"
expect_success "run-tests.sh loads system first"     grep -q ':vendor-test' "$VENDOR_TARGET/bin/run-tests.sh"
expect_success "run-tests.sh calls run-smoke"        grep -q 'vendor-test::run-smoke' "$VENDOR_TARGET/bin/run-tests.sh"
```

- [ ] **Step 2: Run the test — verify the new assertions fail**

```bash
bash bin/test-scaffolder.sh
```

Expected: 7 new failures.

- [ ] **Step 3: Add the smoke.lisp + run-tests.sh templates**

In `bin/new-agent.sh`, after the build.sh block, add:

```bash
# Generate test/smoke.lisp.
mkdir -p "$TARGET_ABS/test"
cat > "$TARGET_ABS/test/smoke.lisp" <<EOF
;;;; test/smoke.lisp — minimal smoke test
;;;; Asserts the agent can be built, spawned, asked, and drained.
;;;; Extend this with real assertions as your agent grows behaviour.

(in-package #:$NAME)

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
EOF

# Generate bin/run-tests.sh.
cat > "$TARGET_ABS/bin/run-tests.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "\$(dirname "\$0")/.."

QL_SETUP="\${HOME}/quicklisp/setup.lisp"
[[ -f "\$QL_SETUP" ]] || QL_SETUP="\${HOME}/.quicklisp/setup.lisp"
[[ -f "\$QL_SETUP" ]] || { echo "quicklisp not found; install it first"; exit 1; }

sbcl --no-userinit --no-sysinit --non-interactive \\
     --load "\$QL_SETUP" \\
     --eval "(push (truename \\"./\\")       asdf:*central-registry*)" \\
     --eval "(push (truename \\"./imago/\\") asdf:*central-registry*)" \\
     --eval "(asdf:load-system :$NAME)" \\
     --load "test/smoke.lisp" \\
     --eval "($NAME::run-smoke)"
EOF
chmod +x "$TARGET_ABS/bin/run-tests.sh"
```

- [ ] **Step 4: Run the test — verify all assertions pass**

```bash
bash bin/test-scaffolder.sh
```

Expected: all 42 assertions pass.

- [ ] **Step 5: Commit**

```bash
git add bin/new-agent.sh bin/test-scaffolder.sh
git commit -m "$(cat <<'EOF'
feat(scaffolder): generate test/smoke.lisp and bin/run-tests.sh

The smoke test asserts only that ask-agent returns non-empty text,
seeding the testing habit without prescribing a framework. run-tests.sh
loads the project's system first so #:<NAME> exists before
test/smoke.lisp's (in-package …) form runs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Generate `README.md`, `LICENSE`, `.gitignore`

**Files:**
- Modify: `bin/test-scaffolder.sh`
- Modify: `bin/new-agent.sh`

- [ ] **Step 1: Add the failing test**

Append to `bin/test-scaffolder.sh`, before the result summary:

```bash
# ---------------------------------------------------------------------------
echo "# README, LICENSE, .gitignore generation"
expect_success "README.md exists"                    test -f "$VENDOR_TARGET/README.md"
expect_success "README mentions project name"        grep -q '# vendor-test' "$VENDOR_TARGET/README.md"
expect_success "README mentions ./imago/"            grep -q 'imago/' "$VENDOR_TARGET/README.md"
expect_success "LICENSE exists"                      test -f "$VENDOR_TARGET/LICENSE"
expect_success "LICENSE is a TODO placeholder"       grep -q 'TODO' "$VENDOR_TARGET/LICENSE"
expect_success ".gitignore exists"                   test -f "$VENDOR_TARGET/.gitignore"
expect_success ".gitignore covers fasls"             grep -q '\*.fasl' "$VENDOR_TARGET/.gitignore"
expect_success ".gitignore anchors binary name"      grep -q '^/vendor-test$' "$VENDOR_TARGET/.gitignore"
```

- [ ] **Step 2: Run the test — verify the new assertions fail**

```bash
bash bin/test-scaffolder.sh
```

Expected: 8 new failures.

- [ ] **Step 3: Add the README, LICENSE, .gitignore templates**

In `bin/new-agent.sh`, after the run-tests.sh block, add:

```bash
# Generate README.md.
cat > "$TARGET_ABS/README.md" <<EOF
# $NAME

An agent built on [anuna-imago](./imago/), vendored at scaffold time.

## Build and run

    bash bin/build.sh                    # ~30s
    ./$NAME --echo "hello"
    ./$NAME --serve 60                   # serve for 60s, drain on SIGTERM

## What's in here

| Path | What |
|---|---|
| \`src/agent.lisp\`   | Your agent. Tools, hooks, provider, prompt — start here. |
| \`imago/\`           | Vendored harness. Edit freely; you own this copy. |
| \`test/smoke.lisp\`  | Smoke test. \`bash bin/run-tests.sh\` |
| \`bin/build.sh\`     | Builds the binary via \`save-image!\`. |

## Next steps

1. Edit \`src/agent.lisp\` — change the system prompt, add a tool.
2. Swap \`make-stub-provider\` for a real one. See \`imago/README.md\`
   "Build your own agent" for Anthropic, OpenRouter, and Z.ai examples.
3. Add identity (\`generate-identity\`) if you'll connect to a router.
4. Read [\`architecture/CHECKING.md\`](https://codeberg.org/anuna/imago/src/branch/main/architecture/CHECKING.md)
   before saving images with secrets in scope.

## Updating the vendored harness

Vendored is vendored — upstream fixes don't flow in automatically. To pull
a newer imago:

    rm -rf imago/
    cp -R /path/to/anuna-imago/{imago.asd,src,theories} imago/

Or re-run \`bin/new-agent.sh\` against an empty directory and diff.
EOF

# Generate LICENSE placeholder.
cat > "$TARGET_ABS/LICENSE" <<EOF
TODO: choose a license. See https://choosealicense.com/.
EOF

# Generate .gitignore.
cat > "$TARGET_ABS/.gitignore" <<EOF
*.fasl
.DS_Store
/$NAME
EOF
```

(The README's "Next steps" item 4 links to the upstream `architecture/CHECKING.md` URL rather than `./imago/architecture/...`, because `architecture/` is intentionally not in the vendoring scope. The spec's "Updating the vendored harness" section already enumerates exactly the three things vendored, so no spec change is needed.)

- [ ] **Step 4: Run the test — verify all assertions pass**

```bash
bash bin/test-scaffolder.sh
```

Expected: all 50 assertions pass.

- [ ] **Step 5: Commit**

```bash
git add bin/new-agent.sh bin/test-scaffolder.sh
git commit -m "$(cat <<'EOF'
feat(scaffolder): generate README.md, LICENSE, .gitignore

README is a single-screen orientation that points at imago's local
docs (in the vendored ./imago/ subtree) and the upstream URL for
architecture/CHECKING.md (which is not vendored). LICENSE is a TODO
placeholder. .gitignore anchors the binary name with a leading slash
to avoid masking deeper directories that happen to share the name.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Print "next steps" hint on success

**Files:**
- Modify: `bin/test-scaffolder.sh`
- Modify: `bin/new-agent.sh`

- [ ] **Step 1: Add the failing test**

Append to `bin/test-scaffolder.sh`, before the result summary:

```bash
# ---------------------------------------------------------------------------
echo "# success-output hint"
HINT_TARGET="$TMP_ROOT/hint-test"
HINT_OUT="$(bash "$SCAFFOLDER" hint-test "$HINT_TARGET" 2>&1)"
expect_success "output mentions 'Scaffolded'"        grep -q 'Scaffolded' <<< "$HINT_OUT"
expect_success "output mentions cd <target>"        grep -q "cd $HINT_TARGET" <<< "$HINT_OUT"
expect_success "output mentions bin/build.sh"       grep -q 'bin/build.sh' <<< "$HINT_OUT"
expect_success "output mentions ./hint-test"        grep -q '\./hint-test' <<< "$HINT_OUT"
```

- [ ] **Step 2: Run the test — verify the new assertions fail**

```bash
bash bin/test-scaffolder.sh
```

Expected: the 3 new "mentions ..." assertions fail (current scaffolder only prints `✓ Scaffolded $NAME at $TARGET`).

- [ ] **Step 3: Replace the trailing echo with the 4-line hint**

In `bin/new-agent.sh`, replace the final `echo "✓ Scaffolded $NAME at $TARGET"` line with:

```bash
cat <<EOF
✓ Scaffolded $NAME at $TARGET
  cd $TARGET
  bash bin/build.sh        # ~30s, produces ./$NAME
  ./$NAME --echo "hi"
EOF
```

- [ ] **Step 4: Run the test — verify all assertions pass**

```bash
bash bin/test-scaffolder.sh
```

Expected: all 54 assertions pass.

- [ ] **Step 5: Commit**

```bash
git add bin/new-agent.sh bin/test-scaffolder.sh
git commit -m "$(cat <<'EOF'
feat(scaffolder): print 4-line next-steps hint on success

Replaces the single-line success echo with a copy-pasteable next-steps
block (cd / build / run) so the new user has unambiguous instructions
about what to do next, including the exact binary name.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: End-to-end build + run-smoke + binary-runs assertions

This task closes the loop on spec acceptance criteria #2–#6. It requires SBCL 2.6+ and Quicklisp on the box; the script gates these checks so it remains usable on machines without those installed.

**Files:**
- Modify: `bin/test-scaffolder.sh`

- [ ] **Step 1: Add the gated end-to-end assertions**

Append to `bin/test-scaffolder.sh`, before the result summary:

```bash
# ---------------------------------------------------------------------------
echo "# end-to-end (requires SBCL + Quicklisp)"
QL_SETUP="${HOME}/quicklisp/setup.lisp"
[[ -f "$QL_SETUP" ]] || QL_SETUP="${HOME}/.quicklisp/setup.lisp"

if command -v sbcl >/dev/null 2>&1 && [[ -f "$QL_SETUP" ]]; then
  E2E="$TMP_ROOT/e2e"
  expect_success "scaffold e2e target"               bash "$SCAFFOLDER" e2e "$E2E"
  expect_success "build.sh runs"                     bash "$E2E/bin/build.sh"
  expect_success "binary was produced"               test -x "$E2E/e2e"
  expect_success "binary --version exits 0"          "$E2E/e2e" --version
  expect_success "binary --echo replies"             "$E2E/e2e" --echo "hello"
  expect_success "run-tests.sh passes"               bash "$E2E/bin/run-tests.sh"

  # Acceptance criterion #6: clean git status after scaffold (no fasls / binary leak).
  (
    cd "$E2E"
    git init -q
    git add .
    UNTRACKED="$(git status --porcelain | grep '^??' || true)"
    [[ -z "$UNTRACKED" ]] || { echo "leak: $UNTRACKED"; exit 1; }
  ) && {
    echo "  ✓ git status clean after build (no untracked fasls/binary)"
    PASS=$((PASS + 1))
  } || {
    echo "  ✗ git status not clean after build"
    FAIL=$((FAIL + 1))
  }
else
  echo "  ⚠ skipped (sbcl or quicklisp not available)"
fi
```

- [ ] **Step 2: Run the test — verify the end-to-end assertions pass**

```bash
bash bin/test-scaffolder.sh
```

Expected on a machine with SBCL + Quicklisp: all 61 assertions pass. The build step takes ~30s. On machines without SBCL/Quicklisp, the section prints "skipped" and 54 assertions still pass.

- [ ] **Step 3: Run the smoke against the real anuna-imago dev environment**

```bash
# Verify the actual built binary works against the real harness.
TMP_REAL="$(mktemp -d)"
bash bin/new-agent.sh demo "$TMP_REAL/demo"
( cd "$TMP_REAL/demo" && bash bin/build.sh && ./demo --echo "real-test" )
echo "exit: $?"
rm -rf "$TMP_REAL"
```

Expected: prints something like `echo: real-test` and exit 0 (the stub provider's canned response — the exact text comes from `imago/src/providers/stub.lisp`).

- [ ] **Step 4: Commit**

```bash
git add bin/test-scaffolder.sh
git commit -m "$(cat <<'EOF'
test(scaffolder): end-to-end build, run, smoke, git-status assertions

Closes acceptance criteria #2–#6: builds the scaffolded binary,
exercises --version and --echo, runs the smoke test, and verifies
git status is clean (no fasls or binary leak under .gitignore).
Gated on sbcl + quicklisp being available so the harness runs on
minimal CI boxes.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: README pointer in imago's own README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a pointer in the imago README**

The imago README's "Build your own agent" section currently shows the user a copy-pasteable snippet. Add a short note immediately before that section pointing to the scaffolder as a turnkey alternative.

In `README.md`, find the "### Build your own agent" line (≈ line 490) and insert above it:

```markdown
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

```

(Note the closing fence of the inner code block is `` ``` ``; the outer markdown will resume after.)

- [ ] **Step 2: Verify the section renders correctly**

```bash
grep -A 12 'Quick start: scaffold' README.md
```

Expected: the new section appears with the 4-line bash snippet and the explanatory paragraph.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs(readme): point users at bin/new-agent.sh scaffolder

Adds a "Quick start" section above "Build your own agent" so a new
user lands on the turnkey scaffolder before the manual snippet. The
snippet stays for users who want to understand what the scaffolder
generates, or who want a single-file agent without the project tree.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Acceptance criteria (mapping back to the spec)

After all tasks complete, run `bash bin/test-scaffolder.sh` and confirm each spec criterion is covered:

| Spec criterion | Covered by |
|---|---|
| #1 Scaffolder runs in <5s | Tasks 1–10 (the `expect_success` for `scaffolds into fresh target` etc.) |
| #2 build.sh produces binary | Task 11 (`build.sh runs`, `binary was produced`) |
| #3 `--version` works | Task 11 (`binary --version exits 0`) |
| #4 `--echo "hello"` works | Task 11 (`binary --echo replies`) |
| #5 run-tests.sh passes | Task 11 (`run-tests.sh passes`) |
| #6 git status clean | Task 11 (`git status clean after build`) |
| #7 Rejects non-empty target | Task 3 (`non-empty target without --force`) |
| #8 Rejects invalid name | Task 1 (3 invalid-name assertions) |
| #9 Rejects scaffolding into imago | Task 2 (2 nesting-refusal assertions) |
