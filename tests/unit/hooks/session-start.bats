#!/usr/bin/env bats
# Tests for scripts/session-start.sh — all source branches.
# v3 spec §4.7: /clear uses ORPHAN POLICY (not auto-pause).

setup() {
  TMPDIR_TEST=$(mktemp -d)
  export CLAUDE_PLUGIN_DATA="$TMPDIR_TEST"
  # Isolate marker writes from the real plugin root
  export CLAUDE_PLUGIN_ROOT="$TMPDIR_TEST"
  export DB_PATH="$TMPDIR_TEST/g.db"

  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export REPO_ROOT

  # Bootstrap schema
  "$REPO_ROOT/tests/helpers/init-test-db.sh" "$DB_PATH"

  NOW=$(python3 -c "import time; print(int(time.time()*1000))")
  RESUME_AT=$((NOW - 5000))
  sqlite3 "$DB_PATH" \
    "INSERT INTO goals (session_id, goal_id, objective, status, resume_at_ms, created_at_ms, updated_at_ms, version)
     VALUES ('s1', 'g1', 'test objective', 'active', $RESUME_AT, $NOW, $NOW, 0);"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

# ---------------------------------------------------------------------------
# 1. source=startup: no DB changes
# ---------------------------------------------------------------------------
@test "SessionStart source=startup is no-op" {
  echo '{"session_id":"s1","source":"startup"}' \
    | "$REPO_ROOT/scripts/session-start.sh"
  STATUS=$(sqlite3 "$DB_PATH" "SELECT status FROM goals WHERE session_id='s1';")
  [ "$STATUS" = "active" ]
  EVENT_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM goal_events;")
  [ "$EVENT_COUNT" = "0" ]
}

# ---------------------------------------------------------------------------
# 2. source=resume: logs session_resumed event
# ---------------------------------------------------------------------------
@test "SessionStart source=resume logs resume event" {
  echo '{"session_id":"s1","source":"resume"}' \
    | "$REPO_ROOT/scripts/session-start.sh"
  STATUS=$(sqlite3 "$DB_PATH" "SELECT status FROM goals WHERE session_id='s1';")
  [ "$STATUS" = "active" ]
  EVENT_TYPE=$(sqlite3 "$DB_PATH" "SELECT event_type FROM goal_events WHERE session_id='s1' LIMIT 1;")
  [ "$EVENT_TYPE" = "session_resumed" ]
}

# ---------------------------------------------------------------------------
# 3. source=clear: ORPHAN POLICY — existing goal must be UNCHANGED (not paused)
# ---------------------------------------------------------------------------
@test "SessionStart source=clear is no-op (orphan policy)" {
  echo '{"session_id":"s1","source":"clear"}' \
    | "$REPO_ROOT/scripts/session-start.sh"
  # Goal must still be active — v3 orphan policy does NOT pause it
  STATUS=$(sqlite3 "$DB_PATH" "SELECT status FROM goals WHERE session_id='s1';")
  [ "$STATUS" = "active" ]
  # No events should have been written
  EVENT_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM goal_events;")
  [ "$EVENT_COUNT" = "0" ]
}

@test "SessionStart source=clear logs orphan policy for new clear session" {
  echo '{"session_id":"new-clear-session","source":"clear"}' \
    | "$REPO_ROOT/scripts/session-start.sh"
  # New clear sessions do not have a goal row, but the hook should still leave
  # an operator-visible breadcrumb that the orphan policy ran.
  ROW_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM goals WHERE session_id='new-clear-session';")
  [ "$ROW_COUNT" = "0" ]
  EVENT_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM goal_events;")
  [ "$EVENT_COUNT" = "0" ]
  run grep -R "source=clear .* orphan policy" "$TMPDIR_TEST/logs"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 4. source=compact: sets accounting_uncertain=1, goal stays active
# ---------------------------------------------------------------------------
@test "SessionStart source=compact sets accounting_uncertain" {
  run bash -c "echo '{\"session_id\":\"s1\",\"source\":\"compact\"}' | \"$REPO_ROOT/scripts/session-start.sh\""
  [ "$status" -eq 0 ]
  UNCERTAIN=$(sqlite3 "$DB_PATH" "SELECT accounting_uncertain FROM goals WHERE session_id='s1';")
  [ "$UNCERTAIN" = "1" ]
  STATUS=$(sqlite3 "$DB_PATH" "SELECT status FROM goals WHERE session_id='s1';")
  [ "$STATUS" = "active" ]
  # Verify systemMessage was emitted
  [[ "$output" == *"accounting flagged uncertain"* ]]
}

# ---------------------------------------------------------------------------
# 5. Preflight: non-writable plugin data dir → clean exit with systemMessage
# ---------------------------------------------------------------------------
@test "SessionStart preflights writable plugin data dir" {
  chmod 555 "$TMPDIR_TEST"
  run bash -c "DB_PATH=\"$DB_PATH\" CLAUDE_PLUGIN_DATA=\"$TMPDIR_TEST\" CLAUDE_PLUGIN_ROOT=\"$TMPDIR_TEST\" \
    bash -c \"echo '{\\\"session_id\\\":\\\"s1\\\",\\\"source\\\":\\\"startup\\\"}' | '$REPO_ROOT/scripts/session-start.sh'\""
  chmod 755 "$TMPDIR_TEST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not writable"* ]]
}

@test "SessionStart preflight creates missing plugin data dir when writable" {
  MISSING_PLUGIN_DATA="$TMPDIR_TEST/missing-plugin-data"
  mkdir -p "$TMPDIR_TEST/home"
  printf '%s' "$MISSING_PLUGIN_DATA" > "$TMPDIR_TEST/.runtime-data-dir"

  [ ! -e "$MISSING_PLUGIN_DATA" ]
  run env -u CLAUDE_PLUGIN_DATA -u DB_PATH \
    HOME="$TMPDIR_TEST/home" \
    CLAUDE_PLUGIN_ROOT="$TMPDIR_TEST" \
    bash -c "echo '{\"session_id\":\"s1\",\"source\":\"startup\"}' | '$REPO_ROOT/scripts/session-start.sh'"

  [ "$status" -eq 0 ]
  [ -d "$MISSING_PLUGIN_DATA" ]
  [[ "$output" != *"not writable"* ]]
}

# ---------------------------------------------------------------------------
# 6. Windows native: exits early with systemMessage, no DB changes
# ---------------------------------------------------------------------------
@test "SessionStart on Windows native exits early with systemMessage" {
  run bash -c "OSTYPE=msys DB_PATH=\"$DB_PATH\" CLAUDE_PLUGIN_DATA=\"$TMPDIR_TEST\" CLAUDE_PLUGIN_ROOT=\"$TMPDIR_TEST\" \
    bash -c \"echo '{\\\"session_id\\\":\\\"s1\\\",\\\"source\\\":\\\"startup\\\"}' | '$REPO_ROOT/scripts/session-start.sh'\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"not supported on Windows native"* ]]
  # DB must be untouched
  STATUS=$(sqlite3 "$DB_PATH" "SELECT status FROM goals WHERE session_id='s1';")
  [ "$STATUS" = "active" ]
}
