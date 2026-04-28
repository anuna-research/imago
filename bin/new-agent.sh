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

# Refuse to scaffold inside the imago tree itself. We compare the
# absolute target against the imago root before creating any dirs.
IMAGO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

# Resolve target's absolute path without requiring it to exist:
# walk up to the first ancestor that does exist, then re-append.
RESOLVE_PARENT="$TARGET"
while [[ ! -d "$RESOLVE_PARENT" ]] && [[ "$RESOLVE_PARENT" != "/" ]]; do
  RESOLVE_PARENT="$(dirname "$RESOLVE_PARENT")"
done
TARGET_PARENT_ABS="$(cd "$RESOLVE_PARENT" && pwd -P)"
# When the target itself already exists, RESOLVE_PARENT == TARGET and
# the suffix-strip would no-op (TARGET doesn't end in "/"). Resolve
# the target directly in that case; otherwise re-append the suffix.
if [[ "$RESOLVE_PARENT" == "$TARGET" ]]; then
  TARGET_ABS_PROBE="$(cd "$TARGET" && pwd -P)"
elif [[ "$RESOLVE_PARENT" == "/" ]]; then
  # Target's entire ancestor chain is absent; TARGET is already absolute.
  TARGET_ABS_PROBE="$TARGET"
else
  TARGET_ABS_PROBE="$TARGET_PARENT_ABS/${TARGET#$RESOLVE_PARENT/}"
fi

# Append "/" to the probe and use the alternation "$IMAGO_ROOT"/*|"$IMAGO_ROOT/"
# so the pattern matches both proper descendants AND the imago root itself.
case "$TARGET_ABS_PROBE/" in
  "$IMAGO_ROOT"/*|"$IMAGO_ROOT/")
    echo "Refusing to scaffold into the imago tree: $TARGET" >&2
    exit 2
    ;;
esac

# Refuse non-empty existing target unless --force was passed.
if [[ -d "$TARGET" ]] && [[ -n "$(ls -A "$TARGET" 2>/dev/null)" ]] && [[ "$FORCE" -eq 0 ]]; then
  echo "Target dir is non-empty: $TARGET (pass --force to scaffold anyway)" >&2
  exit 2
fi

# Now create the target.
mkdir -p "$TARGET"
TARGET_ABS="$(cd "$TARGET" && pwd)"

# Vendor imago: copy imago.asd, src/, theories/ into TARGET/imago/.
mkdir -p "$TARGET_ABS/imago"
cp    "$IMAGO_ROOT/imago.asd"  "$TARGET_ABS/imago/imago.asd"
cp -R "$IMAGO_ROOT/src"        "$TARGET_ABS/imago/src"
cp -R "$IMAGO_ROOT/theories"   "$TARGET_ABS/imago/theories"

echo "✓ Scaffolded $NAME at $TARGET"
