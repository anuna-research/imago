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
echo "# nesting refusal"
expect_failure "refuses target inside imago tree"    bash "$SCAFFOLDER" foo "$REPO_ROOT/examples/foo"
expect_failure "refuses target = imago tree itself"  bash "$SCAFFOLDER" foo "$REPO_ROOT"

# ---------------------------------------------------------------------------
echo "# happy path: nonexistent parent is created"
DEEP_TARGET="$TMP_ROOT/brand-new/nested/dir"
expect_success "scaffolds into nonexistent deep path"  bash "$SCAFFOLDER" deep-test "$DEEP_TARGET"
expect_success "deep target dir exists"                test -d "$DEEP_TARGET"

# ---------------------------------------------------------------------------
echo "# non-empty target rejection"
NONEMPTY="$TMP_ROOT/nonempty"
mkdir -p "$NONEMPTY"
touch "$NONEMPTY/preexisting.txt"
expect_failure "non-empty target without --force"    bash "$SCAFFOLDER" foo "$NONEMPTY"
expect_success "non-empty target WITH --force"       bash "$SCAFFOLDER" foo "$NONEMPTY" --force

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
expect_failure "imago.asd patched: no examples module"  grep -q '(:module "examples"' "$VENDOR_TARGET/imago/imago.asd"
expect_failure "imago.asd patched: no echo file entry"  grep -q '(:file "echo")' "$VENDOR_TARGET/imago/imago.asd"

# ---------------------------------------------------------------------------
echo "# .asd generation"
expect_success ".asd file exists"                    test -f "$VENDOR_TARGET/vendor-test.asd"
expect_success ".asd has correct system name"        grep -q '#:vendor-test' "$VENDOR_TARGET/vendor-test.asd"
expect_success ".asd depends on imago"               grep -q ':depends-on (#:imago)' "$VENDOR_TARGET/vendor-test.asd"

# ---------------------------------------------------------------------------
echo "# src/agent.lisp generation"
expect_success "src/agent.lisp exists"               test -f "$VENDOR_TARGET/src/agent.lisp"
expect_success "defines #:vendor-test package"       grep -q '(defpackage #:vendor-test' "$VENDOR_TARGET/src/agent.lisp"
expect_success "exports toplevel"                    grep -q '#:toplevel' "$VENDOR_TARGET/src/agent.lisp"
expect_success "defines build-agent"                 grep -q '(defun build-agent' "$VENDOR_TARGET/src/agent.lisp"
expect_success "uses stub provider by default"       grep -q 'make-stub-provider' "$VENDOR_TARGET/src/agent.lisp"
expect_success "registers greet tool"                grep -q "define-tool greet" "$VENDOR_TARGET/src/agent.lisp"
expect_success "uses stamped capability"             grep -q '"vendor-test:reply"' "$VENDOR_TARGET/src/agent.lisp"
expect_success "toplevel passes build-agent factory"  grep -Eq "\(anuna-imago:agent-main[[:space:]]+#'build-agent\)" "$VENDOR_TARGET/src/agent.lisp"
expect_failure "toplevel does not pre-spawn an agent" grep -q '(anuna-imago:spawn-agent!' "$VENDOR_TARGET/src/agent.lisp"

# ---------------------------------------------------------------------------
echo "# bin/build.sh generation"
expect_success "build.sh exists"                     test -f "$VENDOR_TARGET/bin/build.sh"
expect_success "build.sh is executable"              test -x "$VENDOR_TARGET/bin/build.sh"
expect_success "build.sh loads :vendor-test"         grep -q ':vendor-test' "$VENDOR_TARGET/bin/build.sh"
expect_success "build.sh names binary correctly"     grep -q '"vendor-test"' "$VENDOR_TARGET/bin/build.sh"
expect_success "build.sh saves with toplevel"        grep -q "vendor-test::toplevel" "$VENDOR_TARGET/bin/build.sh"

# ---------------------------------------------------------------------------
echo "# smoke test + run-tests.sh generation"
expect_success "test/smoke.lisp exists"              test -f "$VENDOR_TARGET/test/smoke.lisp"
expect_success "smoke.lisp uses correct package"     grep -q '(in-package #:vendor-test)' "$VENDOR_TARGET/test/smoke.lisp"
expect_success "smoke.lisp defines run-smoke"        grep -q '(defun run-smoke' "$VENDOR_TARGET/test/smoke.lisp"
expect_success "bin/run-tests.sh exists"             test -f "$VENDOR_TARGET/bin/run-tests.sh"
expect_success "run-tests.sh is executable"          test -x "$VENDOR_TARGET/bin/run-tests.sh"
expect_success "run-tests.sh loads system first"     grep -q ':vendor-test' "$VENDOR_TARGET/bin/run-tests.sh"
expect_success "run-tests.sh calls run-smoke"        grep -q 'vendor-test::run-smoke' "$VENDOR_TARGET/bin/run-tests.sh"

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

# ---------------------------------------------------------------------------
echo "# success-output hint"
HINT_TARGET="$TMP_ROOT/hint-test"
HINT_OUT="$(bash "$SCAFFOLDER" hint-test "$HINT_TARGET" 2>&1)"
expect_success "output mentions 'Scaffolded'"        grep -q 'Scaffolded' <<< "$HINT_OUT"
expect_success "output mentions cd <target>"        grep -q "cd $HINT_TARGET" <<< "$HINT_OUT"
expect_success "output mentions bin/build.sh"       grep -q 'bin/build.sh' <<< "$HINT_OUT"
expect_success "output mentions ./hint-test"        grep -q '\./hint-test' <<< "$HINT_OUT"

# ---------------------------------------------------------------------------
echo "# end-to-end (requires SBCL + Quicklisp)"
QL_SETUP="${HOME}/quicklisp/setup.lisp"
[[ -f "$QL_SETUP" ]] || QL_SETUP="${HOME}/.quicklisp/setup.lisp"

if command -v sbcl >/dev/null 2>&1 && [[ -f "$QL_SETUP" ]]; then
  E2E="$TMP_ROOT/e2e"
  expect_success "scaffold e2e target"               bash "$SCAFFOLDER" e2e "$E2E"
  instrument_factory_count() {
    perl -0pi -e 's/\(defun build-agent \(\)\n/\(defvar *factory-calls* 0\)\n\n\(defun build-agent \(\)\n  \(incf *factory-calls*\)\n/' \
      "$E2E/src/agent.lisp"
    perl -0pi -e 's/\(anuna-imago:make-stub-provider\)/(anuna-imago:make-stub-provider :responder (lambda (message) (format nil "factory-agent-~D: ~A" *factory-calls* message)))/' \
      "$E2E/src/agent.lisp"
    grep -q '(incf \*factory-calls\*)' "$E2E/src/agent.lisp"
  }
  expect_success "instrument custom factory"          instrument_factory_count
  expect_success "build.sh runs"                     bash "$E2E/bin/build.sh"
  expect_success "binary was produced"               test -x "$E2E/e2e"
  e2e_version_includes_imago() {
    "$E2E/e2e" --version 2>&1 | grep -q 'anuna-imago'
  }
  expect_success "binary --version prints anuna-imago"  e2e_version_includes_imago
  e2e_echo_uses_factory_once() {
    "$E2E/e2e" --echo "hello" 2>&1 | grep -q '^factory-agent-1: hello$'
  }
  expect_success "binary --echo uses factory exactly once" e2e_echo_uses_factory_once
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

# ---------------------------------------------------------------------------
echo
echo "result: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
