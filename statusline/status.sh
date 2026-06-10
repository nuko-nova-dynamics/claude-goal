#!/usr/bin/env bash
# claude-goal statusline. Reads the active session's goal and prints a short status string.
# Designed to be called from ~/.claude/settings.json statusLine config.
# Exits 0 with empty output if no goal exists.
set -uo pipefail

# DB path resolution: marker file > env > fallback. Match Phase 4.6 inverted resolver.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
if [[ -f "$PLUGIN_ROOT/.runtime-data-dir" ]]; then
  PLUGIN_DATA=$(cat "$PLUGIN_ROOT/.runtime-data-dir")
elif [[ -n "${CLAUDE_PLUGIN_DATA:-}" ]]; then
  PLUGIN_DATA="$CLAUDE_PLUGIN_DATA"
else
  PLUGIN_DATA="$HOME/.claude/plugins/data/claude-goal"
fi
DB_PATH="$PLUGIN_DATA/goals.db"

SID="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
# Fallback: read from marker file if env vars absent
if [[ -z "$SID" && -f "$PLUGIN_ROOT/.runtime-session-id" ]]; then
  SID=$(cat "$PLUGIN_ROOT/.runtime-session-id")
fi

[[ -z "$SID" || ! -f "$DB_PATH" ]] && exit 0
SID_ESC=${SID//\'/\'\'}

# Use sqlite3 -json output and jq for robust parsing per Phase 4.6 lesson
ROW=$(sqlite3 -bail -cmd ".timeout 5000" -json "$DB_PATH" \
  "SELECT status, paused_reason, tokens_used, subagent_tokens, token_budget, continuations_remaining FROM goals WHERE session_id = '$SID_ESC';" 2>/dev/null || echo "")
[[ -z "$ROW" || "$ROW" == "[]" ]] && exit 0

STATUS=$(echo "$ROW" | jq -r '.[0].status')
REASON=$(echo "$ROW" | jq -r '.[0].paused_reason // ""')
WORKER_TOKENS=$(echo "$ROW" | jq -r '.[0].tokens_used // 0')
SUBAGENT_TOKENS=$(echo "$ROW" | jq -r '.[0].subagent_tokens // 0')
TU=$((WORKER_TOKENS + SUBAGENT_TOKENS))
TB=$(echo "$ROW" | jq -r '.[0].token_budget // ""')

# Format tokens. Autonomous goals run in the millions, so we need M:
#   < 1000        → raw  (e.g. "823")
#   1000–999,999  → "XK" (integer, e.g. "12K", "999K")
#   >= 1,000,000  → "XM" when divisible, otherwise "X.XM" (truncated)
format_tokens() {
  local n=$1
  if (( n >= 1000000 )); then
    if (( n % 1000000 == 0 )); then
      echo "$((n / 1000000))M"
    else
      local m_int=$(( n / 1000000 ))
      local m_frac=$(( (n % 1000000) / 100000 ))
      echo "${m_int}.${m_frac}M"
    fi
  elif (( n >= 1000 )); then
    echo "$((n / 1000))K"
  else
    echo "$n"
  fi
}

case "$STATUS" in
  active)
    if [[ -n "$TB" && "$TB" != "null" ]]; then
      echo "◎ goal active ($(format_tokens $TU) / $(format_tokens $TB))"
    else
      echo "◎ goal active ($(format_tokens $TU))"
    fi
    ;;
  budget_limited) echo "◎ goal unmet (budget exhausted)" ;;
  blocked) echo "◎ goal blocked" ;;
  paused)
    case "$REASON" in
      user) echo "◎ goal paused (user)" ;;
      continuation_cap) echo "◎ goal paused (continuation cap)" ;;
      wall_clock_cap) echo "◎ goal paused (wall-clock cap)" ;;
      cleared) echo "◎ goal paused (cleared)" ;;
      degraded) echo "◎ goal degraded" ;;
      accounting_error) echo "◎ goal paused (accounting error)" ;;
      *) echo "◎ goal paused" ;;
    esac
    ;;
  complete) echo "◎ goal achieved" ;;
  abandoned) echo "◎ goal abandoned" ;;
  *) ;; # unknown status — print nothing
esac
