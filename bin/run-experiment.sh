#!/usr/bin/env bash
# bin/run-experiment.sh — drive a self-modification experiment against
# GLM via the Z.ai Coding Plan and write a markdown report.
#
# Two modes:
#
#   1. Prescribed (default — no --goal). Runs the fixed six-prompt
#      protocol that walks the agent through tool discovery → plan →
#      implement → verify → forbidden-probe → rollback. Comparable
#      across runs; tests safety-stack mechanisms.
#
#   2. Goal-driven (with --goal "..."). Agent is told the goal in its
#      system prompt and driven by `Continue.` each turn until it
#      replies with 'GOAL ACHIEVED:' or hits --turns. Observes whether
#      the model can decompose a real task using the port.
#
# Both modes write reports to /tmp/imago-experiments/. The API key is
# read from ~/.local/share/opencode/auth.json under the
# "zai-coding-plan" slug — no env vars to set.
#
# Examples:
#
#   ./bin/run-experiment.sh
#   ./bin/run-experiment.sh --model glm-4.7
#   ./bin/run-experiment.sh --goal "Define a memoize macro and use it
#     to wrap an expensive function."
#   ./bin/run-experiment.sh --goal "Add structured logging to all
#     successful harness-eval calls." --turns 12

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUICKLISP_SETUP="${QUICKLISP_SETUP:-$HOME/quicklisp/setup.lisp}"

GOAL=""
TURNS=8
MODEL="glm-5.1"
DRY_RUN=0

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --goal "TEXT"   Goal-driven mode. Agent is given TEXT as its goal
                  and driven autonomously until 'GOAL ACHIEVED:' or
                  --turns is reached. Without --goal, runs the
                  prescribed six-prompt safety-stack protocol.
  --turns N       Max turns in goal mode (default: $TURNS). Ignored in
                  prescribed mode (six prompts, fixed).
  --model SLUG    Z.ai model slug (default: $MODEL). Valid:
                  glm-5.1 · glm-5-turbo · glm-4.7 · glm-4.5-air.
  --dry-run       Print the SBCL invocation that would run, then exit.
  -h, --help      This help.

Environment:
  QUICKLISP_SETUP Path to quicklisp/setup.lisp
                  (default: \$HOME/quicklisp/setup.lisp).
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --goal)    GOAL="$2";  shift 2 ;;
    --turns)   TURNS="$2"; shift 2 ;;
    --model)   MODEL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1;  shift ;;
    -h|--help) usage; exit 0 ;;
    --)        shift; break ;;
    *)         echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Validate model slug against what Z.ai's Coding Plan accepts.
case "$MODEL" in
  glm-5.1|glm-5-turbo|glm-4.7|glm-4.5-air) ;;
  *) echo "warning: model '$MODEL' is not a known Z.ai Coding Plan slug" >&2 ;;
esac

# Validate quicklisp present.
if [[ ! -f "$QUICKLISP_SETUP" ]]; then
  echo "error: quicklisp setup.lisp not found at $QUICKLISP_SETUP" >&2
  echo "  override with QUICKLISP_SETUP=/path/to/setup.lisp" >&2
  exit 3
fi

# Validate the opencode auth.json contains a zai-coding-plan key. Don't
# echo the key — just confirm it's there before kicking off SBCL.
AUTH_FILE="$HOME/.local/share/opencode/auth.json"
if [[ ! -f "$AUTH_FILE" ]] || ! grep -q '"zai-coding-plan"' "$AUTH_FILE"; then
  echo "error: zai-coding-plan key not found in $AUTH_FILE" >&2
  echo "  add the key via opencode, or set ANTHROPIC_API_KEY in env" >&2
  exit 4
fi

# Escape user-supplied strings for embedding into Lisp string literals.
escape_lisp_string() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}
GOAL_ESCAPED="$(escape_lisp_string "$GOAL")"
MODEL_ESCAPED="$(escape_lisp_string "$MODEL")"

if [[ -n "$GOAL" ]]; then
  RUN_FORM="(anuna-imago::run-goal-experiment :goal \"$GOAL_ESCAPED\" :max-turns $TURNS :model \"$MODEL_ESCAPED\")"
  MODE_LABEL="goal-driven"
else
  RUN_FORM="(anuna-imago::run-experiment :model \"$MODEL_ESCAPED\")"
  MODE_LABEL="prescribed"
fi

cd "$REPO_ROOT"

if [[ $DRY_RUN -eq 1 ]]; then
  cat <<DRY
Mode:    $MODE_LABEL
Model:   $MODEL
Goal:    ${GOAL:-<n/a — prescribed mode>}
Turns:   $([[ -n "$GOAL" ]] && echo "$TURNS" || echo "6 (fixed)")
SBCL invocation:
  sbcl --non-interactive \\
       --load $QUICKLISP_SETUP \\
       --eval '(push (truename ".") asdf:*central-registry*)' \\
       --eval "(ql:quickload '(:imago :imago/zai) :silent t)" \\
       --eval '(load "examples/self-modifying.lisp")' \\
       --eval '(load "examples/glm-self-mod-experiment.lisp")' \\
       --eval '$RUN_FORM'
DRY
  exit 0
fi

echo ">>> $MODE_LABEL · model=$MODEL${GOAL:+ · goal=\"$GOAL\"}"

exec sbcl --non-interactive \
          --load "$QUICKLISP_SETUP" \
          --eval '(push (truename ".") asdf:*central-registry*)' \
          --eval "(ql:quickload '(:imago :imago/zai) :silent t)" \
          --eval '(load "examples/self-modifying.lisp")' \
          --eval '(load "examples/glm-self-mod-experiment.lisp")' \
          --eval "$RUN_FORM"
