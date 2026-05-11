#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/sqlite-retry.sh"
source "$SCRIPT_DIR/lib/accounting-core.sh"

# Resolve DB path the same way goal-cli.sh does:
# marker file > CLAUDE_PLUGIN_DATA > hardcoded fallback
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "${CLAUDE_PLUGIN_ROOT}/.runtime-data-dir" ]]; then
  PLUGIN_DATA=$(cat "${CLAUDE_PLUGIN_ROOT}/.runtime-data-dir")
elif [[ -n "${CLAUDE_PLUGIN_DATA:-}" ]]; then
  PLUGIN_DATA="$CLAUDE_PLUGIN_DATA"
else
  PLUGIN_DATA="$HOME/.claude/plugins/data/claude-goal"
fi
export DB_PATH="$PLUGIN_DATA/goals.db"

[[ ! -f "$DB_PATH" ]] && { log_info "post-tool-batch: no DB yet; skipping"; exit 0; }

INPUT=$(cat 2>/dev/null || echo "")
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || echo "")
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")

if [[ -z "$SESSION_ID" || -z "$TRANSCRIPT" ]]; then
  log_error "post-tool-batch: missing session_id or transcript_path"
  exit 0
fi

SESSION_ID_ESC=$(sql_escape "$SESSION_ID")

# Check goal exists and is in an accountable status
STATUS=$(sql_retry "SELECT status FROM goals WHERE session_id = '$SESSION_ID_ESC';" 2>/dev/null || echo "")
[[ -z "$STATUS" ]] && exit 0
[[ "$STATUS" != "active" && "$STATUS" != "budget_limited" ]] && exit 0

# Account inline (single-shot transaction within the helper)
account_advance_inline "$SESSION_ID" "$TRANSCRIPT" || log_error "post-tool-batch: accounting failed"

log_info "post-tool-batch: accounting completed for session $SESSION_ID"
exit 0
