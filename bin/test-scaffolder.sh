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
echo
echo "result: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
