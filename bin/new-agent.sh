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

# Refuse to scaffold inside the imago tree itself. We compare the
# absolute target against the imago root before creating any dirs.
IMAGO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

# Resolve target's absolute path without requiring it to exist:
# walk up to the first ancestor that does exist, then re-append.
RESOLVE_PARENT="$TARGET"
while [[ ! -d "$RESOLVE_PARENT" ]] && [[ "$RESOLVE_PARENT" != "/" ]]; do
  RESOLVE_PARENT="$(dirname "$RESOLVE_PARENT")"
done
TARGET_PARENT_ABS="$(cd "$RESOLVE_PARENT" && pwd -P)"
# When the target itself already exists, RESOLVE_PARENT == TARGET and
# the suffix-strip would no-op (TARGET doesn't end in "/"). Resolve
# the target directly in that case; otherwise re-append the suffix.
if [[ "$RESOLVE_PARENT" == "$TARGET" ]]; then
  TARGET_ABS_PROBE="$(cd "$TARGET" && pwd -P)"
elif [[ "$RESOLVE_PARENT" == "/" ]]; then
  # Target's entire ancestor chain is absent; TARGET is already absolute.
  TARGET_ABS_PROBE="$TARGET"
else
  TARGET_ABS_PROBE="$TARGET_PARENT_ABS/${TARGET#$RESOLVE_PARENT/}"
fi

# Append "/" to the probe and use the alternation "$IMAGO_ROOT"/*|"$IMAGO_ROOT/"
# so the pattern matches both proper descendants AND the imago root itself.
case "$TARGET_ABS_PROBE/" in
  "$IMAGO_ROOT"/*|"$IMAGO_ROOT/")
    echo "Refusing to scaffold into the imago tree: $TARGET" >&2
    exit 2
    ;;
esac

# Refuse non-empty existing target unless --force was passed.
if [[ -d "$TARGET" ]] && [[ -n "$(ls -A "$TARGET" 2>/dev/null)" ]] && [[ "$FORCE" -eq 0 ]]; then
  echo "Target dir is non-empty: $TARGET (pass --force to scaffold anyway)" >&2
  exit 2
fi

# Now create the target.
mkdir -p "$TARGET"
TARGET_ABS="$(cd "$TARGET" && pwd)"

# Vendor imago: copy imago.asd, src/, theories/ into TARGET/imago/.
mkdir -p "$TARGET_ABS/imago"
cp    "$IMAGO_ROOT/imago.asd"  "$TARGET_ABS/imago/imago.asd"

# The vendored imago.asd references examples/echo, but we don't vendor
# examples/ (per spec). Patch the asd to drop the examples module and
# rebalance the trailing parens.
sed -i.bak \
  -e '/^   ;; examples\/self-modifying\.lisp is intentionally NOT registered/,/^    :components ((:file "echo")))))$/d' \
  "$TARGET_ABS/imago/imago.asd"
sed -i.bak \
  -e 's/"save-image"))))$/"save-image"))))))/' \
  "$TARGET_ABS/imago/imago.asd"
rm -f "$TARGET_ABS/imago/imago.asd.bak"

cp -R "$IMAGO_ROOT/src"        "$TARGET_ABS/imago/src"
cp -R "$IMAGO_ROOT/theories"   "$TARGET_ABS/imago/theories"

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
     --eval '(anuna-imago:save-image! "$NAME"
                                       :toplevel '"'"'$NAME::toplevel
                                       :executable t)'
EOF
chmod +x "$TARGET_ABS/bin/build.sh"

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

cat <<EOF
✓ Scaffolded $NAME at $TARGET
  cd $TARGET
  bash bin/build.sh        # ~30s, produces ./$NAME
  ./$NAME --echo "hi"
EOF
