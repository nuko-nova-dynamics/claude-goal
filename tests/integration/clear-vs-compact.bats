#!/usr/bin/env bats
# tests/integration/clear-vs-compact.bats
#
# Scenario 4: SessionStart orphan policy (source=clear with new session_id
# does not touch existing goal) vs. compact uncertainty flag.

setup() {
  load ../helpers/fake-claude.sh
  fake_claude_init
  fake_claude_init_db
  NOW_MS=$(python3 -c "import time; print(int(time.time()*1000))")
  GOAL_ID="goal-$(uuidgen | tr '[:upper:]' '[:lower:]')"
  export NOW_MS GOAL_ID
  SESSION_A="$FAKE_SESSION_ID"
  export SESSION_A
}

teardown() {
  fake_claude_cleanup
}

@test "SessionStart source=clear with new session_id does not touch existing goal" {
  # Insert active goal under SESSION_A
  sqlite3 "$FAKE_DATA_DIR/goals.db" "
    INSERT INTO goals
      (session_id, goal_id, objective, status, token_budget, tokens_used,
       continuations_remaining, max_wall_clock_seconds,
       created_at_ms, updated_at_ms)
    VALUES
      ('$SESSION_A', '$GOAL_ID', 'test objective', 'active',
       100000, 0, 50, 14400, $NOW_MS, $NOW_MS);
  "

  # Switch to a NEW session_id (simulates /clear creating a fresh session)
  SESSION_B="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  FAKE_SESSION_ID="$SESSION_B"
  export FAKE_SESSION_ID

  run fake_claude_session_start_hook clear
  [ "$status" -eq 0 ]

  # Goal under SESSION_A must remain active and untouched
  status_val=$(sqlite3 "$FAKE_DATA_DIR/goals.db" \
    "SELECT status FROM goals WHERE session_id = '$SESSION_A';")
  [ "$status_val" = "active" ]
}

@test "SessionStart source=compact on same session sets accounting_uncertain=1" {
  # Insert active goal under the current session
  sqlite3 "$FAKE_DATA_DIR/goals.db" "
    INSERT INTO goals
      (session_id, goal_id, objective, status, token_budget, tokens_used,
       continuations_remaining, max_wall_clock_seconds,
       created_at_ms, updated_at_ms)
    VALUES
      ('$FAKE_SESSION_ID', '$GOAL_ID', 'test objective', 'active',
       100000, 0, 50, 14400, $NOW_MS, $NOW_MS);
  "

  run fake_claude_session_start_hook compact
  [ "$status" -eq 0 ]

  # DB: accounting_uncertain = 1
  uncertain=$(sqlite3 "$FAKE_DATA_DIR/goals.db" \
    "SELECT accounting_uncertain FROM goals WHERE session_id = '$FAKE_SESSION_ID';")
  [ "$uncertain" = "1" ]

  # Hook must emit systemMessage about uncertain accounting
  echo "$output" | grep -qi "accounting"

  # DB: compact_uncertainty_flagged event recorded
  event_count=$(sqlite3 "$FAKE_DATA_DIR/goals.db" \
    "SELECT COUNT(*) FROM goal_events
     WHERE session_id = '$FAKE_SESSION_ID' AND event_type = 'compact_uncertainty_flagged';")
  [ "$event_count" = "1" ]
}
