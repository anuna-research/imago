#!/usr/bin/env bash
# build-echo-image.sh — build a standalone echo-agent binary via save-lisp-and-die
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-${ROOT}/echo-agent}"
QL="${HOME}/quicklisp/setup.lisp"

if [[ ! -f "${QL}" ]]; then
  echo "Quicklisp not found at ${QL}." >&2
  echo "Install: curl -O https://beta.quicklisp.org/quicklisp.lisp" >&2
  echo "         sbcl --no-sysinit --no-userinit --load quicklisp.lisp \\" >&2
  echo "              --eval '(quicklisp-quickstart:install)' --quit"     >&2
  exit 1
fi

sbcl --non-interactive \
     --no-userinit --no-sysinit \
     --load "${QL}" \
     --eval "(push (truename \"${ROOT}/\") asdf:*central-registry*)" \
     --eval "(asdf:load-system :imago)" \
     --eval "(anuna-imago:save-image! \"${OUT}\" :executable t)"

echo
echo "Saved: ${OUT}"
ls -lh "${OUT}"
