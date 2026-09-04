#!/usr/bin/env bash
# run-tests.sh — run milestone and optional plugin test suites
# Usage: bin/run-tests.sh [all|m1..m12|builtin|fileops|identity|openrouter|evolution]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QL="${HOME}/quicklisp/setup.lisp"
TARGET="${1:-all}"

if [[ ! -f "${QL}" ]]; then
  echo "Quicklisp not found at ${QL}." >&2
  exit 1
fi

# Run the aggregate gate in fresh Lisp processes. Several milestone suites
# deliberately exercise live redefinition, so sharing one image would let
# their test-local mutations contaminate later saved-image checks.
if [[ "${TARGET}" == "all" ]]; then
  for suite in m1 m2 m3 m4 m5 m6 m7 m7-wss m7-producer m8 m9 m10 m11 \
               builtin fileops identity m12 openrouter evolution; do
    "${ROOT}/bin/run-tests.sh" "${suite}"
  done
  exit 0
fi

LOADS='(asdf:load-system :imago/test)'

case "${TARGET}" in
  m1)   RUNS='(anuna-imago.test:run-m1-tests)' ;;
  m2)   RUNS='(anuna-imago.test:run-m2-tests)' ;;
  m3)   RUNS='(anuna-imago.test:run-m3-tests)' ;;
  m4)   RUNS='(anuna-imago.test:run-m4-tests)' ;;
  m5)   RUNS='(anuna-imago.test:run-m5-tests)' ;;
  m6)   RUNS='(anuna-imago.test:run-m6-tests)' ;;
  m7)   RUNS='(anuna-imago.test:run-m7-tests)' ;;
  m7-wss) RUNS='(anuna-imago.test:run-m7-wss-tests)' ;;
  m7-producer) RUNS='(anuna-imago.test:run-m7-producer-tests)' ;;
  m8)   RUNS='(anuna-imago.test:run-m8-tests)' ;;
  m9)   RUNS='(anuna-imago.test:run-m9-tests)' ;;
  m10)  RUNS='(anuna-imago.test:run-m10-tests)' ;;
  m11)  RUNS='(anuna-imago.test:run-m11-tests)' ;;
  builtin) RUNS='(anuna-imago.test:run-builtin-tools-tests)' ;;
  fileops) RUNS='(anuna-imago.test:run-fileops-tools-tests)' ;;
  identity) RUNS='(anuna-imago.test:run-identity-tests)' ;;
  m12)  RUNS='(anuna-imago.test:run-m12-tests)' ;;
  openrouter)
        LOADS='(asdf:load-system :imago/openrouter/test)'
        RUNS='(unless (anuna-imago.test:run-openrouter-tests)
                (uiop:quit 1))' ;;
  evolution)
        LOADS='(asdf:load-system :imago/evolution/test)'
        RUNS='(unless (anuna-imago.test:run-evolution-tests)
                (uiop:quit 1))' ;;
  *)    echo "Unknown target: ${TARGET}" >&2; exit 2 ;;
esac

sbcl --non-interactive --no-userinit --no-sysinit \
     --load "${QL}" \
     --eval "(push (truename \"${ROOT}/\") asdf:*central-registry*)" \
     --eval "${LOADS}" \
     --eval "${RUNS}"
