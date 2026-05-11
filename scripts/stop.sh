#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/sqlite-retry.sh"
source "$SCRIPT_DIR/lib/accounting-core.sh"
source "$SCRIPT_DIR/lib/lease.sh"
source "$SCRIPT_DIR/lib/render-template.sh"

# Resolve DB path: marker file > CLAUDE_PLUGIN_DATA > hardcoded fallback
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "${CLAUDE_PLUGIN_ROOT}/.runtime-data-dir" ]]; then
  PLUGIN_DATA=$(cat "${CLAUDE_PLUGIN_ROOT}/.runtime-data-dir")
elif [[ -n "${CLAUDE_PLUGIN_DATA:-}" ]]; then
  PLUGIN_DATA="$CLAUDE_PLUGIN_DATA"
else
  PLUGIN_DATA="$HOME/.claude/plugins/data/claude-goal"
fi
export DB_PATH="$PLUGIN_DATA/goals.db"

PROMPTS_DIR="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}/prompts"

[[ ! -f "$DB_PATH" ]] && { log_info "stop: no DB yet; skipping"; exit 0; }

INPUT=$(cat 2>/dev/null || echo "")
[[ -z "$INPUT" ]] && exit 0

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || echo "")
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")

[[ -z "$SESSION_ID" ]] && exit 0
SESSION_ID_ESC=$(sql_escape "$SESSION_ID")

latest_assistant_uuid() {
  local transcript="$1"
  [[ ! -r "$transcript" ]] && return 0
  grep '"type":"assistant"' "$transcript" 2>/dev/null | tail -1 | jq -r '.uuid // ""' 2>/dev/null || true
}

sql_change_count() {
  local sql_output="$1"
  local changes
  changes=$(printf '%s\n' "$sql_output" | awk '/^[[:space:]]*[0-9]+[[:space:]]*$/ { value=$1 } END { if (value != "") print value; else print "0" }')
  printf '%s' "$changes"
}

# Recursion guard: stop_hook_active=true is present on normal block-driven
# continuation turns too. Treat it as recursive only when Claude re-enters Stop
# without a newer assistant message since our last accounting cursor.
if [[ "$STOP_HOOK_ACTIVE" == "true" ]]; then
  LATEST_ASSISTANT_UUID=$(latest_assistant_uuid "$TRANSCRIPT")
  LAST_ACCOUNTED_UUID=$(sql_retry "SELECT COALESCE(last_accounted_uuid, '') FROM goals WHERE session_id = '$SESSION_ID_ESC';" 2>/dev/null || echo "")
  if [[ -z "$LATEST_ASSISTANT_UUID" || "$LATEST_ASSISTANT_UUID" == "$LAST_ACCOUNTED_UUID" ]]; then
    log_info "stop: stop_hook_active=true with no new assistant turn; recursion guard exit"
    exit 0
  fi
  log_info "stop: stop_hook_active=true but transcript advanced; continuing"
fi

# ms_now cross-platform
NOW=$(ms_now)

# Recursion guard: timing fallback for runtimes where stop_hook_active is absent.
LAST_CONT=$(sql_retry "SELECT COALESCE(last_continuation_at_ms, 0) FROM goals WHERE session_id = '$SESSION_ID_ESC';" 2>/dev/null || echo "")
if [[ "$STOP_HOOK_ACTIVE" != "true" && -n "$LAST_CONT" ]] && (( NOW - LAST_CONT < 500 )); then
  log_info "stop: timing-fallback recursion guard tripped"
  exit 0
fi

# Step A: ALWAYS run accounting catchup first so the completion turn is recorded
account_advance_inline "$SESSION_ID" "$TRANSCRIPT" || log_error "stop: accounting failed"

# Step B: detect update_goal in transcript (Stop stdin has no tool_calls field per P19)
detect_update_goal() {
  local transcript="$1"
  [[ ! -r "$transcript" ]] && return 1
  local recent_assistant
  recent_assistant=$(jq -c 'select(.type == "assistant")' "$transcript" 2>/dev/null | tail -3)
  [[ -z "$recent_assistant" ]] && return 1
  # Match suffix to handle MCP namespacing (mcp__plugin_claude-goal__update_goal etc.)
  printf '%s\n' "$recent_assistant" | jq -s -e '
    any(.[]; ((.message.content // []) | if type == "array" then
      any(.[]; .type == "tool_use" and ((.name // "") | test("update_goal$")))
    else
      false
    end))
  ' >/dev/null 2>&1
}

if detect_update_goal "$TRANSCRIPT"; then
  log_info "stop: update_goal detected in transcript; skipping continuation"
  exit 0
fi

# Step C: re-read goal state after catchup (may have transitioned to budget_limited)
ROW_JSON=$(sqlite3 -bail -json -cmd ".timeout 5000" "$DB_PATH" "
  SELECT
    goal_id,
    objective,
    status,
    token_budget,
    tokens_used,
    time_used_seconds,
    COALESCE(resume_at_ms, 0) AS resume_at_ms,
    continuations_remaining,
    max_wall_clock_seconds,
    budget_limit_reported,
    version
  FROM goals
  WHERE session_id = '$SESSION_ID_ESC'
  LIMIT 1;
" 2>/dev/null || echo "[]")
if ! echo "$ROW_JSON" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
  exit 0
fi

GOAL_ID=$(echo "$ROW_JSON" | jq -r '.[0].goal_id // ""')
OBJECTIVE=$(echo "$ROW_JSON" | jq -r '.[0].objective // ""')
STATUS=$(echo "$ROW_JSON" | jq -r '.[0].status // ""')
TOKEN_BUDGET=$(echo "$ROW_JSON" | jq -r '.[0].token_budget // ""')
TOKENS_USED=$(echo "$ROW_JSON" | jq -r '.[0].tokens_used // 0')
TIME_USED=$(echo "$ROW_JSON" | jq -r '.[0].time_used_seconds // 0')
RESUME_AT=$(echo "$ROW_JSON" | jq -r '.[0].resume_at_ms // 0')
CONT_REM=$(echo "$ROW_JSON" | jq -r '.[0].continuations_remaining // 0')
MAX_WALL=$(echo "$ROW_JSON" | jq -r '.[0].max_wall_clock_seconds // 0')
BL_REPORTED=$(echo "$ROW_JSON" | jq -r '.[0].budget_limit_reported // 0')
VERSION=$(echo "$ROW_JSON" | jq -r '.[0].version // 0')
GOAL_ID_ESC=$(sql_escape "$GOAL_ID")

case "$STATUS" in
  complete|abandoned|paused)
    exit 0
    ;;
  active)
    # handled below
    ;;
  budget_limited)
    if [[ "$BL_REPORTED" = "0" ]]; then
      export OBJECTIVE_RAW="$OBJECTIVE"
      export TOKENS_USED="$TOKENS_USED"
      export TOKEN_BUDGET="${TOKEN_BUDGET:-none}"
      export REMAINING_TOKENS="0"
      export TIME_USED_SECONDS="$TIME_USED"
      export BUDGET_WARNING=""
      REASON=$(render_template "$PROMPTS_DIR/budget-limit.md")
      JSON=$(jq -n --arg r "$REASON" '{decision:"block",reason:$r}')
      if ! echo "$JSON" | jq -e '.decision == "block" and (.reason | length > 0)' >/dev/null 2>&1; then
        log_error "stop: budget-limit JSON failed validation; allowing stop"
        lease_release "$SESSION_ID" $$
        exit 0
      fi
      UPDATE_RESULT=$(sql_retry "
        BEGIN IMMEDIATE;
        UPDATE goals SET
          budget_limit_reported = 1,
          last_continuation_at_ms = $NOW,
          version = version + 1
        WHERE session_id = '$SESSION_ID_ESC'
          AND goal_id = '$GOAL_ID_ESC'
          AND version = $VERSION
          AND budget_limit_reported = 0;
        SELECT changes();
        COMMIT;
      " 2>/dev/null || echo "0")
      UPDATE_CHANGES=$(sql_change_count "$UPDATE_RESULT")
      if [[ "$UPDATE_CHANGES" = "1" ]]; then
        echo "$JSON"
      else
        lease_release "$SESSION_ID" $$
      fi
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac

# Active path: enforce caps
ACTIVE_ELAPSED=0
if [[ "$RESUME_AT" != "0" && -n "$RESUME_AT" ]]; then
  ACTIVE_ELAPSED=$(( (NOW - RESUME_AT) / 1000 ))
  (( ACTIVE_ELAPSED < 0 )) && ACTIVE_ELAPSED=0
fi
TOTAL_WALL=$(( TIME_USED + ACTIVE_ELAPSED ))

if (( CONT_REM <= 0 )); then
  CAP_RESULT=$(sql_retry "
    BEGIN IMMEDIATE;
    UPDATE goals SET status = 'paused', paused_reason = 'continuation_cap',
      time_used_seconds = time_used_seconds + $ACTIVE_ELAPSED, resume_at_ms = NULL,
      version = version + 1, updated_at_ms = $NOW
      WHERE session_id = '$SESSION_ID_ESC' AND goal_id = '$GOAL_ID_ESC' AND version = $VERSION;
    SELECT changes();
    INSERT INTO goal_events (session_id, goal_id, hook_name, event_type, status_before, status_after, pid, created_at_ms)
      SELECT '$SESSION_ID_ESC', '$GOAL_ID_ESC', 'stop', 'cap_reached', 'active', 'paused', $$, $NOW
      WHERE EXISTS (
        SELECT 1 FROM goals
        WHERE session_id = '$SESSION_ID_ESC'
          AND goal_id = '$GOAL_ID_ESC'
          AND version = $((VERSION + 1))
          AND status = 'paused'
          AND paused_reason = 'continuation_cap'
      );
    COMMIT;
  " 2>/dev/null || echo "0")
  CAP_CHANGES=$(sql_change_count "$CAP_RESULT")
  if [[ "$CAP_CHANGES" != "1" ]]; then
    log_info "stop: continuation_cap race lost"
  fi
  exit 0
fi

if (( TOTAL_WALL > MAX_WALL )); then
  CAP_RESULT=$(sql_retry "
    BEGIN IMMEDIATE;
    UPDATE goals SET status = 'paused', paused_reason = 'wall_clock_cap',
      time_used_seconds = time_used_seconds + $ACTIVE_ELAPSED, resume_at_ms = NULL,
      version = version + 1, updated_at_ms = $NOW
      WHERE session_id = '$SESSION_ID_ESC' AND goal_id = '$GOAL_ID_ESC' AND version = $VERSION;
    SELECT changes();
    INSERT INTO goal_events (session_id, goal_id, hook_name, event_type, status_before, status_after, pid, created_at_ms)
      SELECT '$SESSION_ID_ESC', '$GOAL_ID_ESC', 'stop', 'cap_reached', 'active', 'paused', $$, $NOW
      WHERE EXISTS (
        SELECT 1 FROM goals
        WHERE session_id = '$SESSION_ID_ESC'
          AND goal_id = '$GOAL_ID_ESC'
          AND version = $((VERSION + 1))
          AND status = 'paused'
          AND paused_reason = 'wall_clock_cap'
      );
    COMMIT;
  " 2>/dev/null || echo "0")
  CAP_CHANGES=$(sql_change_count "$CAP_RESULT")
  if [[ "$CAP_CHANGES" != "1" ]]; then
    log_info "stop: wall_clock_cap race lost"
  fi
  exit 0
fi

# Acquire lease
if ! lease_acquire "$SESSION_ID" "$GOAL_ID" $$; then
  log_info "stop: lost lease race; allowing stop"
  exit 0
fi

# Decrement counter atomically (with version guard)
DECREMENT_RESULT=$(sql_retry "
  BEGIN IMMEDIATE;
  UPDATE goals SET
    continuations_remaining = continuations_remaining - 1,
    last_continuation_at_ms = $NOW,
    version = version + 1
    WHERE session_id = '$SESSION_ID_ESC' AND goal_id = '$GOAL_ID_ESC' AND version = $VERSION;
  SELECT changes();
  COMMIT;
" 2>/dev/null || echo "0")
DECREMENT_CHANGES=$(sql_change_count "$DECREMENT_RESULT")
if [[ "$DECREMENT_CHANGES" != "1" ]]; then
  log_info "stop: continuation decrement race lost"
  lease_release "$SESSION_ID" $$
  exit 0
fi

# Compute remaining tokens + budget warning
REMAINING="unbounded"
WARNING=""
if [[ -n "$TOKEN_BUDGET" ]]; then
  REM=$(( TOKEN_BUDGET - TOKENS_USED ))
  (( REM < 0 )) && REM=0
  REMAINING="$REM"
  PCT=$(( REM * 100 / TOKEN_BUDGET ))
  if (( PCT < 20 )); then
    WARNING="

Budget warning: ${PCT}% remaining"
  fi
fi

export OBJECTIVE_RAW="$OBJECTIVE"
export TOKENS_USED
export TIME_USED_SECONDS="$TOTAL_WALL"
export REMAINING_TOKENS="$REMAINING"
export BUDGET_WARNING="$WARNING"
export TOKEN_BUDGET="${TOKEN_BUDGET:-none}"

REASON=$(render_template "$PROMPTS_DIR/continuation.md")
JSON=$(jq -n --arg r "$REASON" '{decision:"block",reason:$r}')

if ! echo "$JSON" | jq -e '.decision == "block" and (.reason | length > 0)' >/dev/null 2>&1; then
  log_error "stop: rendered JSON failed validation; allowing stop"
  lease_release "$SESSION_ID" $$
  exit 0
fi

# Record continuation_injected event, gated by WHERE EXISTS (version race loser won't emit)
sql_retry "INSERT INTO goal_events (session_id, goal_id, hook_name, event_type, decision, status_before, status_after, version_before, version_after, pid, created_at_ms)
  SELECT '$SESSION_ID_ESC', '$GOAL_ID_ESC', 'stop', 'continuation_injected', 'block', 'active', 'active', $VERSION, $((VERSION + 1)), $$, $NOW
  WHERE EXISTS (
    SELECT 1 FROM goals WHERE session_id = '$SESSION_ID_ESC' AND goal_id = '$GOAL_ID_ESC' AND version = $((VERSION + 1))
  );"

# Release the lease — next Stop hook needs to acquire its own
lease_release "$SESSION_ID" $$

echo "$JSON"
exit 0
