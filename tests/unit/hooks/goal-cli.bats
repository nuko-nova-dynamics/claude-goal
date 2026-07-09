#!/usr/bin/env bats

setup() {
  TMPDIR_TEST=$(mktemp -d)
  mkdir -p "$TMPDIR_TEST/plugin-root"
  export CLAUDE_PLUGIN_DATA="$TMPDIR_TEST"
  export DB_PATH="$TMPDIR_TEST/goals.db"
  export CLAUDE_PLUGIN_ROOT="$TMPDIR_TEST/plugin-root"
  export CLAUDE_SESSION_ID="test-session"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export REPO_ROOT
  CLI="$REPO_ROOT/scripts/goal-cli.sh"
  export CLI
  "$REPO_ROOT/tests/helpers/init-test-db.sh" "$DB_PATH"
  # macOS-compatible millisecond timestamp helper
  ms_now() { python3 -c "import time; print(int(time.time()*1000))"; }
}
teardown() { rm -rf "$TMPDIR_TEST"; }

@test "status with no goal exits 2" {
  run "$CLI" status
  [ "$status" -eq 2 ]
}

@test "stale runtime-data-dir marker pointing at a deleted dir is ignored" {
  NOW=$(ms_now)
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, resume_at_ms, created_at_ms, updated_at_ms) VALUES ('test-session', 'g1', 'real objective', 'active', $NOW, $NOW, $NOW);"
  # Leak a marker at plugin root that points to a dir that no longer exists.
  printf '%s' "$TMPDIR_TEST/vanished-tmpdir" > "$CLAUDE_PLUGIN_ROOT/.runtime-data-dir"
  run "$CLI" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"real objective"* ]]
}

@test "valid runtime-data-dir marker still wins over DB_PATH override" {
  MARKER_DIR="$TMPDIR_TEST/marker-data"
  mkdir -p "$MARKER_DIR"
  "$REPO_ROOT/tests/helpers/init-test-db.sh" "$MARKER_DIR/goals.db"
  NOW=$(ms_now)
  sqlite3 "$MARKER_DIR/goals.db" "INSERT INTO goals (session_id, goal_id, objective, status, resume_at_ms, created_at_ms, updated_at_ms) VALUES ('test-session', 'g1', 'marker objective', 'active', $NOW, $NOW, $NOW);"
  printf '%s' "$MARKER_DIR" > "$CLAUDE_PLUGIN_ROOT/.runtime-data-dir"
  run "$CLI" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"marker objective"* ]]
}

@test "status JSON includes remaining_tokens and bool accounting_uncertain" {
  NOW=$(ms_now)
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, token_budget, budget_source, tokens_used, subagent_tokens, resume_at_ms, created_at_ms, updated_at_ms) VALUES ('test-session', 'g1', 'x', 'active', 1000, 'tokens', 200, 50, $NOW, $NOW, $NOW);"
  run "$CLI" status --format=json
  [ "$status" -eq 0 ]
  REM=$(echo "$output" | jq -r '.remaining_tokens')
  AU=$(echo "$output" | jq -r '.accounting_uncertain')
  SUBAGENT=$(echo "$output" | jq -r '.subagent_tokens')
  TOTAL=$(echo "$output" | jq -r '.total_tokens_used')
  [ "$REM" = "750" ]
  [ "$AU" = "false" ]
  [ "$SUBAGENT" = "50" ]
  [ "$TOTAL" = "250" ]
}

@test "status text includes subagent tokens" {
  NOW=$(ms_now)
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, token_budget, budget_source, tokens_used, subagent_tokens, resume_at_ms, created_at_ms, updated_at_ms) VALUES ('test-session', 'g1', 'x', 'active', 1000, 'tokens', 200, 50, $NOW, $NOW, $NOW);"
  run "$CLI" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Tokens: 200 / 1000 (750 remaining)"* ]]
  [[ "$output" == *"Subagent tokens: 50"* ]]
}

@test "status text displays budget profile source" {
  NOW=$(ms_now)
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, token_budget, budget_profile, budget_source, tokens_used, resume_at_ms, created_at_ms, updated_at_ms) VALUES ('test-session', 'g1', 'x', 'active', 5000000, 'deep', 'auto', 200, $NOW, $NOW, $NOW);"
  run "$CLI" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Budget: deep profile (auto)"* ]]
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

@test "resume restarts blocked goal" {
  NOW=$(ms_now)
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, created_at_ms, updated_at_ms) VALUES ('test-session', 'g1', 'x', 'blocked', $NOW, $NOW);"

  run "$CLI" resume
  [ "$status" -eq 0 ]

  STATUS=$(sqlite3 "$DB_PATH" "SELECT status, paused_reason IS NULL, resume_at_ms IS NOT NULL FROM goals WHERE session_id='test-session';")
  [ "$STATUS" = "active|1|1" ]
  EVENT=$(sqlite3 "$DB_PATH" "SELECT status_before || '>' || status_after FROM goal_events WHERE event_type='goal_resumed' ORDER BY id DESC LIMIT 1;")
  [ "$EVENT" = "blocked>active" ]
}

@test "extend without flags exits 1" {
  run "$CLI" extend
  [ "$status" -eq 1 ]
}

@test "extend rejects non-integer continuation input before SQL" {
  NOW=$(ms_now)
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, paused_reason, created_at_ms, updated_at_ms) VALUES ('test-session', 'g1', 'x', 'paused', 'continuation_cap', $NOW, $NOW);"

  run "$CLI" extend --add-continuations "1; DROP TABLE goals;"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--add-continuations must be a positive integer"* ]]

  TABLE_EXISTS=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='goals';")
  [ "$TABLE_EXISTS" = "1" ]
}

@test "extend --add-tokens resumes budget_limited goal" {
  NOW=$(ms_now)
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, token_budget, budget_source, tokens_used, subagent_tokens, budget_limit_reported, created_at_ms, updated_at_ms) VALUES ('test-session', 'g1', 'x', 'budget_limited', 1000, 'tokens', 900, 100, 1, $NOW, $NOW);"

  run "$CLI" extend --add-tokens 500
  [ "$status" -eq 0 ]

  ROW=$(sqlite3 "$DB_PATH" "SELECT status || '|' || token_budget || '|' || budget_limit_reported || '|' || (resume_at_ms IS NOT NULL) FROM goals WHERE session_id='test-session';")
  [ "$ROW" = "active|1500|0|1" ]
}

@test "extend --add-tokens sets budget on active unbudgeted goal" {
  NOW=$(ms_now)
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, tokens_used, subagent_tokens, created_at_ms, updated_at_ms) VALUES ('test-session', 'g1', 'x', 'active', 900, 100, $NOW, $NOW);"

  run "$CLI" extend --add-tokens 500
  [ "$status" -eq 0 ]

  ROW=$(sqlite3 "$DB_PATH" "SELECT token_budget || '|' || budget_source || '|' || COALESCE(budget_profile, '') FROM goals WHERE session_id='test-session';")
  [ "$ROW" = "1500|tokens|" ]
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

@test "pause resume abandon write lifecycle events" {
  NOW=$(ms_now)
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, resume_at_ms, created_at_ms, updated_at_ms) VALUES ('test-session', 'g1', 'x', 'active', $NOW, $NOW, $NOW);"

  run "$CLI" pause
  [ "$status" -eq 0 ]
  STATUS=$(sqlite3 "$DB_PATH" "SELECT status, paused_reason FROM goals WHERE session_id='test-session';")
  [ "$STATUS" = "paused|user" ]

  run "$CLI" resume
  [ "$status" -eq 0 ]
  STATUS=$(sqlite3 "$DB_PATH" "SELECT status, paused_reason IS NULL FROM goals WHERE session_id='test-session';")
  [ "$STATUS" = "active|1" ]

  run "$CLI" abandon
  [ "$status" -eq 0 ]
  STATUS=$(sqlite3 "$DB_PATH" "SELECT status, resume_at_ms IS NULL FROM goals WHERE session_id='test-session';")
  [ "$STATUS" = "abandoned|1" ]

  EVENTS=$(sqlite3 "$DB_PATH" "SELECT group_concat(event_type || ':' || status_before || '>' || status_after, ',') FROM goal_events WHERE session_id='test-session' ORDER BY id;")
  [ "$EVENTS" = "goal_paused:active>paused,goal_resumed:paused>active,goal_abandoned:active>abandoned" ]
}

@test "abandon clears cap pause reason" {
  NOW=$(ms_now)
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, paused_reason, resume_at_ms, created_at_ms, updated_at_ms) VALUES ('test-session', 'g1', 'x', 'paused', 'continuation_cap', $NOW, $NOW, $NOW);"

  run "$CLI" abandon
  [ "$status" -eq 0 ]

  STATUS=$(sqlite3 "$DB_PATH" "SELECT status, paused_reason IS NULL, resume_at_ms IS NULL FROM goals WHERE session_id='test-session';")
  [ "$STATUS" = "abandoned|1|1" ]
}

@test "doctor runs without session_id" {
  unset CLAUDE_SESSION_ID
  run "$CLI" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude-goal doctor"* ]]
}

@test "goal-cli reads .runtime-session-id marker when CLAUDE_SESSION_ID is unset" {
  # Setup: no env var, but a marker file pointing to a real DB
  ALT_DIR=$(mktemp -d)
  export CLAUDE_PLUGIN_ROOT="$ALT_DIR"
  printf '%s' "marker-session-id" > "$ALT_DIR/.runtime-session-id"

  # Pre-seed the goal db with a row keyed by 'marker-session-id'
  NOW=$(ms_now)
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, created_at_ms, updated_at_ms) VALUES ('marker-session-id', 'g1', 'x', 'active', $NOW, $NOW);"

  run env -u CLAUDE_SESSION_ID "$CLI" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"marker-session-id"* ]] || [[ "$output" == *"Goal: x"* ]]
  rm -rf "$ALT_DIR"
}

@test "status resolves DB from marker file when CLAUDE_PLUGIN_DATA is unset" {
  # Create an alternate data dir with its own DB
  ALT_DATA=$(mktemp -d)
  ALT_DB="$ALT_DATA/goals.db"
  "$REPO_ROOT/tests/helpers/init-test-db.sh" "$ALT_DB"

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

@test "status resolves DB from marker file when CLAUDE_PLUGIN_DATA points elsewhere" {
  RIGHT_DATA=$(mktemp -d)
  RIGHT_DB="$RIGHT_DATA/goals.db"
  "$REPO_ROOT/tests/helpers/init-test-db.sh" "$RIGHT_DB"

  WRONG_DATA=$(mktemp -d)
  WRONG_DB="$WRONG_DATA/goals.db"
  "$REPO_ROOT/tests/helpers/init-test-db.sh" "$WRONG_DB"

  FAKE_ROOT=$(mktemp -d)
  printf '%s' "$RIGHT_DATA" > "$FAKE_ROOT/.runtime-data-dir"

  NOW=$(python3 -c "import time; print(int(time.time()*1000))")
  sqlite3 "$RIGHT_DB" "INSERT INTO goals (session_id, goal_id, objective, status, created_at_ms, updated_at_ms) VALUES ('test-session', 'g-marker', 'marker-wins-test', 'active', $NOW, $NOW);"
  sqlite3 "$WRONG_DB" "INSERT INTO goals (session_id, goal_id, objective, status, created_at_ms, updated_at_ms) VALUES ('test-session', 'g-env', 'env-loses-test', 'active', $NOW, $NOW);"

  run env -u DB_PATH \
      CLAUDE_PLUGIN_DATA="$WRONG_DATA" \
      CLAUDE_PLUGIN_ROOT="$FAKE_ROOT" \
      CLAUDE_SESSION_ID="test-session" \
      "$CLI" status --format=json
  [ "$status" -eq 0 ]
  OBJ=$(echo "$output" | jq -r '.objective // ""')
  [ "$OBJ" = "marker-wins-test" ]

  rm -rf "$RIGHT_DATA" "$WRONG_DATA" "$FAKE_ROOT"
}

@test "status resolves DB from marker file when DB_PATH points elsewhere" {
  RIGHT_DATA=$(mktemp -d)
  RIGHT_DB="$RIGHT_DATA/goals.db"
  "$REPO_ROOT/tests/helpers/init-test-db.sh" "$RIGHT_DB"

  WRONG_DATA=$(mktemp -d)
  WRONG_DB="$WRONG_DATA/goals.db"

  FAKE_ROOT=$(mktemp -d)
  printf '%s' "$RIGHT_DATA" > "$FAKE_ROOT/.runtime-data-dir"

  NOW=$(python3 -c "import time; print(int(time.time()*1000))")
  sqlite3 "$RIGHT_DB" "INSERT INTO goals (session_id, goal_id, objective, status, created_at_ms, updated_at_ms) VALUES ('test-session', 'g-marker', 'marker-beats-db-path', 'active', $NOW, $NOW);"

  run env \
      DB_PATH="$WRONG_DB" \
      CLAUDE_PLUGIN_ROOT="$FAKE_ROOT" \
      CLAUDE_SESSION_ID="test-session" \
      "$CLI" status --format=json
  [ "$status" -eq 0 ]
  OBJ=$(echo "$output" | jq -r '.objective // ""')
  [ "$OBJ" = "marker-beats-db-path" ]

  rm -rf "$RIGHT_DATA" "$WRONG_DATA" "$FAKE_ROOT"
}

@test "status resolves DB from script-adjacent marker when CLAUDE_PLUGIN_ROOT is unset" {
  RIGHT_DATA=$(mktemp -d)
  RIGHT_DB="$RIGHT_DATA/goals.db"
  "$REPO_ROOT/tests/helpers/init-test-db.sh" "$RIGHT_DB"

  WRONG_DATA=$(mktemp -d)
  WRONG_DB="$WRONG_DATA/goals.db"

  FAKE_ROOT=$(mktemp -d)
  ln -s "$REPO_ROOT/scripts" "$FAKE_ROOT/scripts"
  printf '%s' "$RIGHT_DATA" > "$FAKE_ROOT/.runtime-data-dir"

  NOW=$(python3 -c "import time; print(int(time.time()*1000))")
  sqlite3 "$RIGHT_DB" "INSERT INTO goals (session_id, goal_id, objective, status, created_at_ms, updated_at_ms) VALUES ('test-session', 'g-marker', 'script-adjacent-marker', 'active', $NOW, $NOW);"

  run env -u CLAUDE_PLUGIN_ROOT \
      DB_PATH="$WRONG_DB" \
      CLAUDE_SESSION_ID="test-session" \
      "$FAKE_ROOT/scripts/goal-cli.sh" status --format=json
  [ "$status" -eq 0 ]
  OBJ=$(echo "$output" | jq -r '.objective // ""')
  [ "$OBJ" = "script-adjacent-marker" ]

  rm -rf "$RIGHT_DATA" "$WRONG_DATA" "$FAKE_ROOT"
}
