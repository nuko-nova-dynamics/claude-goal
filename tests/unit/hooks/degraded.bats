#!/usr/bin/env bats

setup() {
  TMPDIR_TEST=$(mktemp -d)
  export DB_PATH="$TMPDIR_TEST/g.db"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  sqlite3 "$DB_PATH" < "$REPO_ROOT/mcp/goal-server/src/migrations/001_initial.sql"
  source "$REPO_ROOT/scripts/lib/sqlite-retry.sh"
  source "$REPO_ROOT/scripts/lib/accounting-core.sh"
  NOW=$(python3 -c "import time; print(int(time.time()*1000))")
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, resume_at_ms, created_at_ms, updated_at_ms)
    VALUES ('s1', 'g1', 'x', 'active', $NOW, $NOW, $NOW);"
}

teardown() { rm -rf "$TMPDIR_TEST"; }

@test "pause_as_degraded flips active to paused/degraded" {
  pause_as_degraded "s1"
  ROW=$(sqlite3 "$DB_PATH" "SELECT status, paused_reason FROM goals WHERE session_id='s1';")
  [[ "$ROW" == "paused|degraded" ]]
}

@test "pause_as_degraded is idempotent (already-paused goal stays paused/degraded)" {
  pause_as_degraded "s1"
  pause_as_degraded "s1"  # second call should be no-op
  COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM goals WHERE session_id='s1' AND status='paused';")
  [ "$COUNT" = "1" ]
  STATUS=$(sqlite3 "$DB_PATH" "SELECT status, paused_reason FROM goals WHERE session_id='s1';")
  [[ "$STATUS" == "paused|degraded" ]]
}

@test "pause_as_degraded is no-op when session does not exist" {
  pause_as_degraded "nonexistent-session"
  # Original active goal should be untouched
  COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM goals WHERE session_id='s1' AND status='active';")
  [ "$COUNT" = "1" ]
}
