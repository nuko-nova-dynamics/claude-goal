#!/usr/bin/env bats
# tests/integration/token-accounting.bats
#
# Scenario 2: PostToolBatch accumulates input+cache_creation+output tokens,
# excludes cache_read_input_tokens.

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

@test "PostToolBatch sums input+cache_creation+output across new assistant messages" {
  sqlite3 "$FAKE_DATA_DIR/goals.db" "
    INSERT INTO goals
      (session_id, goal_id, objective, status, token_budget, tokens_used,
       continuations_remaining, max_wall_clock_seconds, resume_at_ms,
       created_at_ms, updated_at_ms)
    VALUES
      ('$FAKE_SESSION_ID', '$GOAL_ID', 'test objective', 'active',
       500000, 0, 50, 14400, $NOW_MS, $NOW_MS, $NOW_MS);
  "

  fake_claude_user_message "hi"
  # input=100, cache_creation=50, output=20 → delta 170
  fake_claude_assistant_message "response 1" 100 20 50 0

  run fake_claude_posttool_hook
  [ "$status" -eq 0 ]

  tokens=$(sqlite3 "$FAKE_DATA_DIR/goals.db" \
    "SELECT tokens_used FROM goals WHERE session_id = '$FAKE_SESSION_ID';")
  [ "$tokens" = "170" ]

  # Second message: input=200, cache_creation=100, output=0 → delta 300
  fake_claude_assistant_message "response 2" 200 0 100 0

  run fake_claude_posttool_hook
  [ "$status" -eq 0 ]

  tokens=$(sqlite3 "$FAKE_DATA_DIR/goals.db" \
    "SELECT tokens_used FROM goals WHERE session_id = '$FAKE_SESSION_ID';")
  [ "$tokens" = "470" ]
}

@test "PostToolBatch excludes cache_read_input_tokens from token accounting" {
  sqlite3 "$FAKE_DATA_DIR/goals.db" "
    INSERT INTO goals
      (session_id, goal_id, objective, status, token_budget, tokens_used,
       continuations_remaining, max_wall_clock_seconds, resume_at_ms,
       created_at_ms, updated_at_ms)
    VALUES
      ('$FAKE_SESSION_ID', '$GOAL_ID', 'test objective', 'active',
       500000, 0, 50, 14400, $NOW_MS, $NOW_MS, $NOW_MS);
  "

  fake_claude_user_message "hi"
  # input=100, output=50, cache_creation=0, cache_read=9999 (should be ignored)
  fake_claude_assistant_message "response" 100 50 0 9999

  run fake_claude_posttool_hook
  [ "$status" -eq 0 ]

  # Expected: 100 + 0 (cache_create) + 50 = 150, NOT 10149
  tokens=$(sqlite3 "$FAKE_DATA_DIR/goals.db" \
    "SELECT tokens_used FROM goals WHERE session_id = '$FAKE_SESSION_ID';")
  [ "$tokens" = "150" ]
}
