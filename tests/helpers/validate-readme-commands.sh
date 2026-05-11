#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
README="$REPO_ROOT/README.md"
MISSING=0

# Extract /goal-* command names from backticks in README.
# Plugin commands are all hyphen-suffixed (e.g. /goal-start, /goal-pause). The bare
# /goal mentioned in the README refers to Claude Code's native command, NOT this
# plugin, so we deliberately skip it by requiring at least one hyphen.
for cmd in $(grep -oE '`/goal-[a-z]+' "$README" | sort -u | tr -d '`'); do
  NAME="${cmd#/}"
  SKILL_FILE="$REPO_ROOT/skills/$NAME/SKILL.md"
  if [[ ! -f "$SKILL_FILE" ]]; then
    echo "MISSING: $cmd → expected $SKILL_FILE"
    MISSING=$((MISSING + 1))
  else
    echo "OK: $cmd → $SKILL_FILE"
  fi
done

if [[ "$MISSING" -gt 0 ]]; then
  echo ""
  echo "$MISSING commands referenced in README have no skill file."
  exit 1
fi

echo ""
echo "All README slash commands map to existing skill files."
