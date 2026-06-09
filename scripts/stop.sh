#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/sqlite-retry.sh"
source "$SCRIPT_DIR/lib/accounting-core.sh"
source "$SCRIPT_DIR/lib/lease.sh"
source "$SCRIPT_DIR/lib/render-template.sh"

# Safety-net ERR trap: fires on unset-variable errors, pipeline failures,
# or explicit non-zero returns from helper functions (set -uo pipefail is active).
# Flips the active goal to paused/degraded and exits fail-open.
trap 'pause_as_degraded "${SESSION_ID:-}" 2>/dev/null; lease_release "${SESSION_ID:-}" $$ 2>/dev/null; echo "{\"systemMessage\":\"goal pursuit degraded; see ${CLAUDE_PLUGIN_DATA:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/data/claude-goal}}/logs/\"}"; exit 0' ERR

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
LAST_ASSISTANT_MESSAGE=$(echo "$INPUT" | jq -r '.last_assistant_message // ""' 2>/dev/null || echo "")

[[ -z "$SESSION_ID" ]] && exit 0
SESSION_ID_ESC=$(sql_escape "$SESSION_ID")

latest_assistant_uuid() {
  local transcript="$1"
  [[ ! -r "$transcript" ]] && return 0
  grep '"type":"assistant"' "$transcript" 2>/dev/null | tail -1 | jq -r '.uuid // ""' 2>/dev/null || true
}

assistant_message_hash() {
  local message="$1"
  [[ -z "$message" ]] && { printf ''; return 0; }
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$message" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$message" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$message" | cksum | awk '{print $1 "-" $2}'
  fi
}

sql_change_count() {
  local sql_output="$1"
  local changes
  changes=$(printf '%s\n' "$sql_output" | awk '/^[[:space:]]*[0-9]+[[:space:]]*$/ { value=$1 } END { if (value != "") print value; else print "0" }')
  printf '%s' "$changes"
}

LATEST_ASSISTANT_UUID=$(latest_assistant_uuid "$TRANSCRIPT")
LATEST_ASSISTANT_MESSAGE_HASH=$(assistant_message_hash "$LAST_ASSISTANT_MESSAGE")

# ms_now cross-platform
NOW=$(ms_now)

# Recursion guard: stop_hook_active=true is present on normal block-driven
# continuation turns too. Treat it as recursive only when Claude re-enters Stop
# without either a newer transcript assistant UUID or a newer hook-provided
# assistant message since our last injected block. Claude can invoke Stop before
# flushing the new assistant line to JSONL, so the stdin message is load-bearing.
if [[ "$STOP_HOOK_ACTIVE" == "true" ]]; then
  LAST_BLOCK_JSON=$(sql_retry "
    SELECT json_object(
      'assistant_uuid', COALESCE(json_extract(payload_json, '$.assistant_uuid'), ''),
      'assistant_message_hash', COALESCE(json_extract(payload_json, '$.assistant_message_hash'), ''),
      'created_at_ms', COALESCE(created_at_ms, 0)
    )
    FROM goal_events
    WHERE session_id = '$SESSION_ID_ESC'
      AND hook_name = 'stop'
      AND decision = 'block'
    ORDER BY created_at_ms DESC, id DESC
    LIMIT 1;
  " 2>/dev/null || echo "")
  LAST_BLOCK_UUID=$(echo "${LAST_BLOCK_JSON:-{}}" | jq -r '.assistant_uuid // ""' 2>/dev/null || echo "")
  LAST_BLOCK_MESSAGE_HASH=$(echo "${LAST_BLOCK_JSON:-{}}" | jq -r '.assistant_message_hash // ""' 2>/dev/null || echo "")
  LAST_BLOCK_AT=$(echo "${LAST_BLOCK_JSON:-{}}" | jq -r '.created_at_ms // 0' 2>/dev/null || echo "0")

  TRANSCRIPT_ADVANCED=false
  HOOK_MESSAGE_ADVANCED=false
  if [[ -n "$LATEST_ASSISTANT_UUID" && "$LATEST_ASSISTANT_UUID" != "$LAST_BLOCK_UUID" ]]; then
    TRANSCRIPT_ADVANCED=true
  fi
  if [[ -n "$LATEST_ASSISTANT_MESSAGE_HASH" && "$LATEST_ASSISTANT_MESSAGE_HASH" != "$LAST_BLOCK_MESSAGE_HASH" ]]; then
    HOOK_MESSAGE_ADVANCED=true
  fi
  ELAPSED_SINCE_BLOCK=0
  if [[ "$LAST_BLOCK_AT" =~ ^[0-9]+$ ]] && (( LAST_BLOCK_AT > 0 )); then
    ELAPSED_SINCE_BLOCK=$(( NOW - LAST_BLOCK_AT ))
  fi

  if [[ ("$TRANSCRIPT_ADVANCED" != "true" && "$HOOK_MESSAGE_ADVANCED" != "true") && $ELAPSED_SINCE_BLOCK -le 750 ]]; then
    log_info "stop: stop_hook_active=true with no new assistant turn; recursion guard exit"
    exit 0
  fi
  log_info "stop: stop_hook_active=true but assistant turn advanced; continuing"
fi

# Recursion guard: timing fallback for runtimes where stop_hook_active is absent.
LAST_CONT=$(sql_retry "SELECT COALESCE(last_continuation_at_ms, 0) FROM goals WHERE session_id = '$SESSION_ID_ESC';" 2>/dev/null || echo "")
if [[ "$STOP_HOOK_ACTIVE" != "true" && -n "$LAST_CONT" ]] && (( NOW - LAST_CONT < 500 )); then
  log_info "stop: timing-fallback recursion guard tripped"
  exit 0
fi

# Step A: ALWAYS run accounting catchup first so the completion turn is recorded
recover_legacy_usage_cap_pause "$SESSION_ID" "stop" || true
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

# Step C: re-read goal state after catchup (may have transitioned to budget_limited)
ROW_JSON=$(sqlite3 -bail -json -cmd ".timeout 5000" "$DB_PATH" "
  SELECT
    goal_id,
    objective,
    status,
    token_budget,
    tokens_used,
    subagent_tokens,
    time_used_seconds,
    COALESCE(resume_at_ms, 0) AS resume_at_ms,
    continuations_remaining,
    max_wall_clock_seconds,
    budget_limit_reported,
    last_accounted_byte_offset,
    version
  FROM goals
  WHERE session_id = '$SESSION_ID_ESC'
  LIMIT 1;
" 2>/dev/null || echo "[]")
if ! echo "$ROW_JSON" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1; then
  if [[ -s "$DB_PATH" ]]; then
    if ! sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='goals';" >/dev/null 2>&1; then
      log_error "stop: DB appears corrupt"
      echo '{"systemMessage":"claude-goal: DB corruption detected; see logs/"}'
      exit 0
    fi
  fi
  exit 0
fi

GOAL_ID=$(echo "$ROW_JSON" | jq -r '.[0].goal_id // ""')
OBJECTIVE=$(echo "$ROW_JSON" | jq -r '.[0].objective // ""')
STATUS=$(echo "$ROW_JSON" | jq -r '.[0].status // ""')
TOKEN_BUDGET=$(echo "$ROW_JSON" | jq -r '.[0].token_budget // ""')
TOKENS_USED=$(echo "$ROW_JSON" | jq -r '.[0].tokens_used // 0')
SUBAGENT_TOKENS=$(echo "$ROW_JSON" | jq -r '.[0].subagent_tokens // 0')
TOTAL_TOKENS_USED=$(( TOKENS_USED + SUBAGENT_TOKENS ))
TIME_USED=$(echo "$ROW_JSON" | jq -r '.[0].time_used_seconds // 0')
RESUME_AT=$(echo "$ROW_JSON" | jq -r '.[0].resume_at_ms // 0')
CONT_REM=$(echo "$ROW_JSON" | jq -r '.[0].continuations_remaining // 0')
MAX_WALL=$(echo "$ROW_JSON" | jq -r '.[0].max_wall_clock_seconds // 0')
BL_REPORTED=$(echo "$ROW_JSON" | jq -r '.[0].budget_limit_reported // 0')
LAST_ACCOUNTED_OFFSET=$(echo "$ROW_JSON" | jq -r '.[0].last_accounted_byte_offset // 0')
VERSION=$(echo "$ROW_JSON" | jq -r '.[0].version // 0')
GOAL_ID_ESC=$(sql_escape "$GOAL_ID")
STATUS_ESC=$(sql_escape "$STATUS")

run_f5_final_turn_accounting() {
  local baseline_offset="$LAST_ACCOUNTED_OFFSET"
  local before_offset="$LAST_ACCOUNTED_OFFSET"
  local after_offset

  for retry in 1 2 3 4 5; do
    sleep 0.1
    account_advance_inline "$SESSION_ID" "$TRANSCRIPT" 2>/dev/null || true
    after_offset=$(sql_retry "SELECT COALESCE(last_accounted_byte_offset, 0) FROM goals WHERE session_id = '$SESSION_ID_ESC';" 2>/dev/null || echo "0")
    if [[ "$after_offset" != "$before_offset" ]]; then
      log_info "stop: F5 caught additional tokens after ${retry} retry (offset $before_offset -> $after_offset)"
      before_offset="$after_offset"
      # Continue looping in case more content flushes.
    fi
  done

  # Record an explicit F5 event only when a retry advanced beyond the
  # start-of-hook accounting cursor. This can happen after update_goal has
  # already transitioned the row to complete.
  local final_row final_status final_version final_offset final_status_esc
  final_row=$(sql_retry "SELECT status || '|' || version || '|' || COALESCE(last_accounted_byte_offset, 0) FROM goals WHERE session_id = '$SESSION_ID_ESC' AND goal_id = '$GOAL_ID_ESC';" 2>/dev/null || echo "")
  IFS='|' read -r final_status final_version final_offset <<< "$final_row"
  if [[ "$final_offset" =~ ^[0-9]+$ && "$final_version" =~ ^[0-9]+$ ]] && (( final_offset > baseline_offset )); then
    final_status_esc=$(sql_escape "$final_status")
    sql_retry "INSERT INTO goal_events
      (session_id, goal_id, hook_name, event_type, status_before, status_after,
       version_before, version_after, pid, created_at_ms)
      VALUES ('$SESSION_ID_ESC', '$GOAL_ID_ESC', 'stop', 'final_turn_accounted',
        '$STATUS_ESC', '$final_status_esc', $VERSION, $final_version, $$, $NOW);" 2>/dev/null || true
  fi
}

case "$STATUS" in
  complete)
    log_info "stop: goal already complete; running F5 final-turn accounting"
    run_f5_final_turn_accounting
    exit 0
    ;;
  blocked)
    log_info "stop: goal blocked; running F5 final-turn accounting"
    run_f5_final_turn_accounting
    exit 0
    ;;
  abandoned|paused)
    exit 0
    ;;
  active)
    if detect_update_goal "$TRANSCRIPT"; then
      log_info "stop: update_goal detected in transcript; running F5 final-turn accounting"
      # F5 fix: the completion turn's tokens may not yet be in the transcript at the
      # start-of-hook accounting pass (line 122). Retry with brief sleeps to let
      # Claude Code flush the transcript, then re-account. Bounded so a slow flush
      # doesn't hang the hook. Captures tokens that would otherwise be lost because
      # no further hook invocation fires after the goal transitions to complete.
      run_f5_final_turn_accounting
      exit 0
    fi
    ;;
  budget_limited)
    if [[ "$BL_REPORTED" = "0" ]]; then
      export OBJECTIVE_RAW="$OBJECTIVE"
      export WORKER_TOKENS_USED="$TOKENS_USED"
      export SUBAGENT_TOKENS
      export TOKENS_USED="$TOTAL_TOKENS_USED"
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
        INSERT INTO goal_events
          (session_id, goal_id, hook_name, event_type, status_before, status_after,
           version_before, version_after, decision, pid, created_at_ms)
          SELECT '$SESSION_ID_ESC', '$GOAL_ID_ESC', 'stop', 'budget_limit_reported',
            'budget_limited', 'budget_limited', $VERSION, $((VERSION + 1)), 'block', $$, $NOW
          WHERE EXISTS (
            SELECT 1 FROM goals
            WHERE session_id = '$SESSION_ID_ESC'
              AND goal_id = '$GOAL_ID_ESC'
              AND version = $((VERSION + 1))
              AND budget_limit_reported = 1
          );
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
  REM=$(( TOKEN_BUDGET - TOTAL_TOKENS_USED ))
  (( REM < 0 )) && REM=0
  REMAINING="$REM"
  PCT=$(( REM * 100 / TOKEN_BUDGET ))
  if (( PCT < 20 )); then
    WARNING="

Budget warning: ${PCT}% remaining"
  fi
fi

export OBJECTIVE_RAW="$OBJECTIVE"
export SESSION_ID
export WORKER_TOKENS_USED="$TOKENS_USED"
export SUBAGENT_TOKENS
export TOKENS_USED="$TOTAL_TOKENS_USED"
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

CONT_PAYLOAD=$(jq -cn \
  --arg assistant_uuid "$LATEST_ASSISTANT_UUID" \
  --arg assistant_message_hash "$LATEST_ASSISTANT_MESSAGE_HASH" \
  --argjson last_accounted_byte_offset "${LAST_ACCOUNTED_OFFSET:-0}" \
  '{assistant_uuid:$assistant_uuid, assistant_message_hash:$assistant_message_hash, last_accounted_byte_offset:$last_accounted_byte_offset}')
CONT_PAYLOAD_ESC=$(sql_escape "$CONT_PAYLOAD")

# Record continuation_injected event, gated by WHERE EXISTS (version race loser won't emit).
# The insert result controls whether we return a block; if the agent evaluator
# completed the goal after the decrement, the event insert is skipped and Stop
# exits silently instead of forcing one extra continuation turn.
CONT_EVENT_RESULT=$(sql_retry "
  INSERT INTO goal_events (session_id, goal_id, hook_name, event_type, decision, status_before, status_after, version_before, version_after, payload_json, pid, created_at_ms)
  SELECT '$SESSION_ID_ESC', '$GOAL_ID_ESC', 'stop', 'continuation_injected', 'block', 'active', 'active', $VERSION, $((VERSION + 1)), '$CONT_PAYLOAD_ESC', $$, $NOW
  WHERE EXISTS (
    SELECT 1 FROM goals
    WHERE session_id = '$SESSION_ID_ESC'
      AND goal_id = '$GOAL_ID_ESC'
      AND version = $((VERSION + 1))
      AND status = 'active'
  );
  SELECT changes();
" 2>/dev/null || echo "0")
CONT_EVENT_CHANGES=$(sql_change_count "$CONT_EVENT_RESULT")

# Release the lease — next Stop hook needs to acquire its own
lease_release "$SESSION_ID" $$

if [[ "$CONT_EVENT_CHANGES" = "1" ]]; then
  echo "$JSON"
else
  log_info "stop: continuation event race lost"
fi
exit 0
