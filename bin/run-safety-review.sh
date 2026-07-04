#!/usr/bin/env bash
# run-safety-review.sh — SPEC-012 recursion-safety subset under two optimization
# policies (t12-review). Loads :imago/test twice, forcing a full recompile each
# time so the OPTIMIZE proclamation actually shapes the emitted code:
#
#   pass 1: (optimize (speed 3) (safety 0) (debug 0))   — compiled/fast
#   pass 2: (optimize (speed 0) (safety 3) (debug 3))   — safe/interpreted-ish
#
# Runs the m12 pre-filter/lift tests that map to TEST-011..TEST-015 and asserts
# both passes are green (no safety check optimized away).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QL="${HOME}/quicklisp/setup.lisp"

# The recursion-safety subset: the pre-filter denylist + safety-layer +
# defgeneric + lift tests (TEST-005/006, TEST-011..015, F1/F5/F7 corollaries).
SUBSET='(let ((anuna-imago.test::*failures* 0))
          (anuna-imago.test::test-m12-prefilter-denies-cl-mischief)
          (anuna-imago.test::test-m12-prefilter-denies-setf-bypasses)
          (anuna-imago.test::test-m12-prefilter-denies-defmethod-against-safety-layer)
          (anuna-imago.test::test-m12-prefilter-denies-defgeneric-against-safety-layer)
          (anuna-imago.test::test-m12-prefilter-denies-safety-var-assignment)
          (anuna-imago.test::test-m12-reasoner-ipc-in-safety-set)
          (anuna-imago.test::test-m12-lift-captures-assignment-target)
          (anuna-imago.test::test-m12-prefilter-passes-benign)
          (anuna-imago.test::test-m12-lift-defmethod-shape)
          (anuna-imago.test::test-m12-lift-progn-buried-targets)
          (anuna-imago.test::test-m12-lift-test-015-progn-unregister)
          (anuna-imago.test::test-m12-lift-stable-across-whitespace)
          (format t "~%=== SUBSET RESULT: ~D failure(s) ===~%"
                  anuna-imago.test::*failures*)
          (if (zerop anuna-imago.test::*failures*)
              (sb-ext:exit :code 0)
              (sb-ext:exit :code 1)))'

run_pass () {
  local label="$1" policy="$2"
  echo "############################################################"
  echo "# PASS: ${label}"
  echo "# policy: ${policy}"
  echo "############################################################"
  sbcl --non-interactive --no-userinit --no-sysinit \
       --load "${QL}" \
       --eval "(proclaim '(optimize ${policy}))" \
       --eval "(push (truename \"${ROOT}/\") asdf:*central-registry*)" \
       --eval "(asdf:load-system :imago/test :force t)" \
       --eval "${SUBSET}"
}

rc=0
run_pass "compiled-fast" "(speed 3) (safety 0) (debug 0)" || rc=$?
echo
run_pass "safe-interpreted" "(speed 0) (safety 3) (debug 3)" || rc=$?

echo
if [[ "${rc}" -eq 0 ]]; then
  echo ">>> BOTH OPTIMIZATION MODES GREEN"
else
  echo ">>> DIVERGENCE OR FAILURE (rc=${rc})"
fi
exit "${rc}"
