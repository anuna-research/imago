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
