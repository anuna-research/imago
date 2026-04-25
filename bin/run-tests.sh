#!/usr/bin/env bash
# run-tests.sh — run all milestone test suites
# Usage: bin/run-tests.sh [m1|m2|m3|m4|m5|m8|m9|all]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QL="${HOME}/quicklisp/setup.lisp"
TARGET="${1:-all}"

if [[ ! -f "${QL}" ]]; then
  echo "Quicklisp not found at ${QL}." >&2
  exit 1
fi

case "${TARGET}" in
  all)  RUNS='(progn (anuna-imago.test:run-m1-tests)
                       (anuna-imago.test:run-m2-tests)
                       (anuna-imago.test:run-m3-tests)
                       (anuna-imago.test:run-m4-tests)
                       (anuna-imago.test:run-m5-tests)
                       (anuna-imago.test:run-m8-tests)
                       (anuna-imago.test:run-m9-tests))' ;;
  m1)   RUNS='(anuna-imago.test:run-m1-tests)' ;;
  m2)   RUNS='(anuna-imago.test:run-m2-tests)' ;;
  m3)   RUNS='(anuna-imago.test:run-m3-tests)' ;;
  m4)   RUNS='(anuna-imago.test:run-m4-tests)' ;;
  m5)   RUNS='(anuna-imago.test:run-m5-tests)' ;;
  m8)   RUNS='(anuna-imago.test:run-m8-tests)' ;;
  m9)   RUNS='(anuna-imago.test:run-m9-tests)' ;;
  *)    echo "Unknown target: ${TARGET}" >&2; exit 2 ;;
esac

sbcl --non-interactive --no-userinit --no-sysinit \
     --load "${QL}" \
     --eval "(push (truename \"${ROOT}/\") asdf:*central-registry*)" \
     --eval "(asdf:load-system :imago/test)" \
     --eval "${RUNS}"
