#!/usr/bin/env bats
# tests/integration/completion-detection.bats
#
# Scenario 5: Stop hook detects update_goal in transcript and stays silent;
# other tool_use still triggers continuation injection.

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

@test "Stop hook detects update_goal in transcript and remains silent" {
  sqlite3 "$FAKE_DATA_DIR/goals.db" "
    INSERT INTO goals
      (session_id, goal_id, objective, status, token_budget, tokens_used,
       continuations_remaining, max_wall_clock_seconds, resume_at_ms,
       created_at_ms, updated_at_ms)
    VALUES
      ('$FAKE_SESSION_ID', '$GOAL_ID', 'test objective', 'active',
       100000, 0, 50, 14400, $NOW_MS, $NOW_MS, $NOW_MS);
  "

  fake_claude_user_message "finalize"
  fake_claude_tool_use "update_goal" '{"status":"complete"}' 50 10

  run fake_claude_stop_hook
  [ "$status" -eq 0 ]

  # Hook must stay silent — no decision field
  decision=$(echo "$output" | jq -r '.decision // empty' 2>/dev/null || true)
  [ -z "$decision" ]

  # No continuation_injected event
  event_count=$(sqlite3 "$FAKE_DATA_DIR/goals.db" \
    "SELECT COUNT(*) FROM goal_events
     WHERE session_id = '$FAKE_SESSION_ID' AND event_type = 'continuation_injected';")
  [ "$event_count" = "0" ]
}

@test "Stop hook with tool_use other than update_goal still injects continuation" {
  sqlite3 "$FAKE_DATA_DIR/goals.db" "
    INSERT INTO goals
      (session_id, goal_id, objective, status, token_budget, tokens_used,
       continuations_remaining, max_wall_clock_seconds, resume_at_ms,
       created_at_ms, updated_at_ms)
    VALUES
      ('$FAKE_SESSION_ID', '$GOAL_ID', 'test objective', 'active',
       100000, 0, 50, 14400, $NOW_MS, $NOW_MS, $NOW_MS);
  "

  fake_claude_user_message "read something"
  fake_claude_tool_use "Read" '{"file_path":"/tmp/test"}' 30 10

  run fake_claude_stop_hook
  [ "$status" -eq 0 ]

  decision=$(echo "$output" | jq -r '.decision // empty')
  [ "$decision" = "block" ]
}
