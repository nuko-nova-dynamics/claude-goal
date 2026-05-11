#!/usr/bin/env bats
# tests/integration/budget-exhaustion.bats
#
# Scenario 3: When tokens_used >= token_budget after PostToolBatch,
# the goal flips to budget_limited. The Stop hook then emits the
# budget-limit block once (budget_limit_reported=0→1).

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

@test "PostToolBatch flips active to budget_limited when tokens_used >= token_budget" {
  # tokens_used=99000, token_budget=100000 — one more batch puts us over
  sqlite3 "$FAKE_DATA_DIR/goals.db" "
    INSERT INTO goals
      (session_id, goal_id, objective, status, token_budget, tokens_used,
       continuations_remaining, max_wall_clock_seconds, resume_at_ms,
       created_at_ms, updated_at_ms)
    VALUES
      ('$FAKE_SESSION_ID', '$GOAL_ID', 'test objective', 'active',
       100000, 99000, 50, 14400, $NOW_MS, $NOW_MS, $NOW_MS);
  "

  fake_claude_user_message "do work"
  # input=2000, cache_creation=500, output=0 → delta 2500 → total 101500 ≥ 100000
  fake_claude_assistant_message "progress" 2000 0 500 0

  run fake_claude_posttool_hook
  [ "$status" -eq 0 ]

  status_val=$(sqlite3 "$FAKE_DATA_DIR/goals.db" \
    "SELECT status FROM goals WHERE session_id = '$FAKE_SESSION_ID';")
  [ "$status_val" = "budget_limited" ]
}

@test "Stop hook emits budget-limit block when status is budget_limited and not yet reported" {
  # Insert a goal already in budget_limited state, budget_limit_reported=0
  sqlite3 "$FAKE_DATA_DIR/goals.db" "
    INSERT INTO goals
      (session_id, goal_id, objective, status, token_budget, tokens_used,
       continuations_remaining, max_wall_clock_seconds, resume_at_ms,
       budget_limit_reported, created_at_ms, updated_at_ms)
    VALUES
      ('$FAKE_SESSION_ID', '$GOAL_ID', 'test objective', 'budget_limited',
       100000, 101500, 50, 14400, $NOW_MS, 0, $NOW_MS, $NOW_MS);
  "

  fake_claude_user_message "wrap up"
  fake_claude_assistant_message "wrapping" 10 10 0 0

  run fake_claude_stop_hook
  [ "$status" -eq 0 ]

  decision=$(echo "$output" | jq -r '.decision // empty')
  [ "$decision" = "block" ]

  # DB: budget_limit_reported should now be 1
  reported=$(sqlite3 "$FAKE_DATA_DIR/goals.db" \
    "SELECT budget_limit_reported FROM goals WHERE session_id = '$FAKE_SESSION_ID';")
  [ "$reported" = "1" ]

  event_count=$(sqlite3 "$FAKE_DATA_DIR/goals.db" \
    "SELECT COUNT(*) FROM goal_events WHERE session_id = '$FAKE_SESSION_ID' AND event_type = 'budget_limit_reported' AND decision = 'block';")
  [ "$event_count" = "1" ]
}
