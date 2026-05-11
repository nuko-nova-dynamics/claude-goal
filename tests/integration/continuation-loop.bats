#!/usr/bin/env bats
# tests/integration/continuation-loop.bats
#
# Scenario 1: Stop hook injects a continuation when a goal is active,
# and stays silent when no goal exists.

setup() {
  load ../helpers/fake-claude.sh
  fake_claude_init
  fake_claude_init_db
  NOW_MS=$(python3 -c "import time; print(int(time.time()*1000))")
  GOAL_ID="goal-$(uuidgen | tr '[:upper:]' '[:lower:]')"
  export NOW_MS GOAL_ID
}

teardown() {
  fake_claude_cleanup
}

@test "Stop hook on active goal emits decision: block with continuation prompt" {
  # Seed DB with an active goal
  sqlite3 "$FAKE_DATA_DIR/goals.db" "
    INSERT INTO goals
      (session_id, goal_id, objective, status, token_budget, tokens_used,
       continuations_remaining, max_wall_clock_seconds, resume_at_ms,
       created_at_ms, updated_at_ms)
    VALUES
      ('$FAKE_SESSION_ID', '$GOAL_ID', 'test objective', 'active',
       100000, 0, 50, 14400, $NOW_MS, $NOW_MS, $NOW_MS);
  "

  fake_claude_user_message "do something"
  fake_claude_assistant_message "working on it" 100 50 0 0

  run fake_claude_stop_hook
  [ "$status" -eq 0 ]

  # Must emit decision=block
  decision=$(echo "$output" | jq -r '.decision // empty')
  [ "$decision" = "block" ]

  # Reason must contain content (continuation.md rendered)
  reason_len=$(echo "$output" | jq -r '.reason // "" | length')
  [ "$reason_len" -gt 0 ]

  # DB: continuations_remaining decremented by 1 (was 50 → 49)
  remaining=$(sqlite3 "$FAKE_DATA_DIR/goals.db" \
    "SELECT continuations_remaining FROM goals WHERE session_id = '$FAKE_SESSION_ID';")
  [ "$remaining" = "49" ]

  # DB: a continuation_injected event was recorded
  event_count=$(sqlite3 "$FAKE_DATA_DIR/goals.db" \
    "SELECT COUNT(*) FROM goal_events
     WHERE session_id = '$FAKE_SESSION_ID' AND event_type = 'continuation_injected';")
  [ "$event_count" = "1" ]
}

@test "Stop hook does not inject when no active goal" {
  # No goal in DB
  fake_claude_user_message "hello"
  fake_claude_assistant_message "hello back" 10 5 0 0

  run fake_claude_stop_hook
  [ "$status" -eq 0 ]

  # No decision field expected (empty output or no decision key)
  decision=$(echo "$output" | jq -r '.decision // empty' 2>/dev/null || true)
  [ -z "$decision" ]
}
