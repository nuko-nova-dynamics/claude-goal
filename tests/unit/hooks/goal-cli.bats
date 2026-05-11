#!/usr/bin/env bats

setup() {
  TMPDIR_TEST=$(mktemp -d)
  export CLAUDE_PLUGIN_DATA="$TMPDIR_TEST"
  export DB_PATH="$TMPDIR_TEST/goals.db"
  export CLAUDE_SESSION_ID="test-session"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export REPO_ROOT
  CLI="$REPO_ROOT/scripts/goal-cli.sh"
  export CLI
  sqlite3 "$DB_PATH" < "$REPO_ROOT/mcp/goal-server/src/migrations/001_initial.sql"
  # macOS-compatible millisecond timestamp helper
  ms_now() { python3 -c "import time; print(int(time.time()*1000))"; }
}
teardown() { rm -rf "$TMPDIR_TEST"; }

@test "status with no goal exits 2" {
  run "$CLI" status
  [ "$status" -eq 2 ]
}

@test "status JSON includes remaining_tokens and bool accounting_uncertain" {
  NOW=$(ms_now)
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, token_budget, tokens_used, resume_at_ms, created_at_ms, updated_at_ms) VALUES ('test-session', 'g1', 'x', 'active', 1000, 200, $NOW, $NOW, $NOW);"
  run "$CLI" status --format=json
  [ "$status" -eq 0 ]
  REM=$(echo "$output" | jq -r '.remaining_tokens')
  AU=$(echo "$output" | jq -r '.accounting_uncertain')
  [ "$REM" = "800" ]
  [ "$AU" = "false" ]
}

@test "pause when no active goal exits 2" {
  run "$CLI" pause
  [ "$status" -eq 2 ]
}

@test "resume rejects continuation_cap reason with exit 3" {
  NOW=$(ms_now)
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, paused_reason, created_at_ms, updated_at_ms) VALUES ('test-session', 'g1', 'x', 'paused', 'continuation_cap', $NOW, $NOW);"
  run "$CLI" resume
  [ "$status" -eq 3 ]
}

@test "extend without flags exits 1" {
  run "$CLI" extend
  [ "$status" -eq 1 ]
}

@test "reconcile --accept-reset clears flag and resumes accounting_error pause" {
  NOW=$(ms_now)
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, paused_reason, accounting_uncertain, created_at_ms, updated_at_ms) VALUES ('test-session', 'g1', 'x', 'paused', 'accounting_error', 1, $NOW, $NOW);"
  run "$CLI" reconcile --accept-reset
  [ "$status" -eq 0 ]
  STATUS=$(sqlite3 "$DB_PATH" "SELECT status FROM goals WHERE session_id='test-session';")
  AU=$(sqlite3 "$DB_PATH" "SELECT accounting_uncertain FROM goals WHERE session_id='test-session';")
  [ "$STATUS" = "active" ]
  [ "$AU" = "0" ]
}

@test "doctor runs without session_id" {
  unset CLAUDE_SESSION_ID
  run "$CLI" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude-goal doctor"* ]]
}

@test "status resolves DB from marker file when CLAUDE_PLUGIN_DATA is unset" {
  # Create an alternate data dir with its own DB
  ALT_DATA=$(mktemp -d)
  ALT_DB="$ALT_DATA/goals.db"
  sqlite3 "$ALT_DB" < "$REPO_ROOT/mcp/goal-server/src/migrations/001_initial.sql"

  # Create a plugin root dir and write the marker pointing to ALT_DATA
  FAKE_ROOT=$(mktemp -d)
  printf '%s' "$ALT_DATA" > "$FAKE_ROOT/.runtime-data-dir"

  # Insert a sentinel row in the alternate DB
  NOW=$(python3 -c "import time; print(int(time.time()*1000))")
  sqlite3 "$ALT_DB" "INSERT INTO goals (session_id, goal_id, objective, status, created_at_ms, updated_at_ms) VALUES ('test-session', 'g-marker', 'marker-test', 'active', $NOW, $NOW);"

  # Run goal-cli with CLAUDE_PLUGIN_DATA unset; DB_PATH unset; CLAUDE_PLUGIN_ROOT pointing to FAKE_ROOT
  run env -u CLAUDE_PLUGIN_DATA -u DB_PATH \
      CLAUDE_PLUGIN_ROOT="$FAKE_ROOT" \
      CLAUDE_SESSION_ID="test-session" \
      "$CLI" status --format=json
  [ "$status" -eq 0 ]
  OBJ=$(echo "$output" | jq -r '.objective // ""')
  [ "$OBJ" = "marker-test" ]

  rm -rf "$ALT_DATA" "$FAKE_ROOT"
}
