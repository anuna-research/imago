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
echo
echo "result: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
