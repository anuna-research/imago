#!/usr/bin/env bash
# build-echo-image.sh — build a standalone echo-agent binary via save-lisp-and-die
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-${ROOT}/echo-agent}"

sbcl --non-interactive \
     --no-userinit --no-sysinit \
     --eval "(require :asdf)" \
     --eval "(push (truename \"${ROOT}/\") asdf:*central-registry*)" \
     --eval "(asdf:load-system :imago)" \
     --eval "(anuna-imago:save-image! \"${OUT}\" :executable t)"

echo
echo "Saved: ${OUT}"
ls -lh "${OUT}"
