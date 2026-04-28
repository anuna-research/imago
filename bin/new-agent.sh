#!/usr/bin/env bash
# bin/new-agent.sh — scaffold a standalone anuna-imago agent project.
# Usage: bin/new-agent.sh <name> <target-dir> [--force]
set -euo pipefail

usage() {
  cat >&2 <<USAGE
Usage: bin/new-agent.sh <name> <target-dir> [--force]

  <name>        agent name; must match ^[a-z][a-z0-9-]*$
  <target-dir>  must not be a non-empty existing dir, unless --force is given;
                must not be inside the imago tree itself.

Example:
  bash bin/new-agent.sh my-agent ../my-agent
USAGE
  exit 2
}

[[ $# -ge 2 ]] || usage

NAME="$1"
TARGET="$2"
FORCE=0
shift 2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1 ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
  shift
done

# Validate name.
if [[ ! "$NAME" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "Invalid <name>: $NAME (must match ^[a-z][a-z0-9-]*\$)" >&2
  exit 2
fi

# Create target dir.
mkdir -p "$TARGET"
TARGET_ABS="$(cd "$TARGET" && pwd)"

echo "✓ Scaffolded $NAME at $TARGET"
