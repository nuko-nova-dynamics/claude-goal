#!/usr/bin/env bats
# Phase 5 Task 5.2: fail-open vs degraded matrix tests
# Verifies that all hook scripts NEVER deadlock the user, never emit non-JSON to stdout
# (Stop hook specifically), and exit 0 on every error class.

setup() {
  TMPDIR_TEST=$(mktemp -d)
  export CLAUDE_PLUGIN_DATA="$TMPDIR_TEST"
  export DB_PATH="$TMPDIR_TEST/goals.db"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export REPO_ROOT CLAUDE_PLUGIN_ROOT="$REPO_ROOT"

  # Save real marker if it exists, replace with test marker
  if [[ -f "$REPO_ROOT/.runtime-data-dir" ]]; then
    cp "$REPO_ROOT/.runtime-data-dir" "$REPO_ROOT/.runtime-data-dir.bak"
  fi
  printf '%s' "$TMPDIR_TEST" > "$REPO_ROOT/.runtime-data-dir"

  # Create schema at the path the scripts will resolve to: $TMPDIR_TEST/goals.db
  "$REPO_ROOT/tests/helpers/init-test-db.sh" "$DB_PATH" >/dev/null 2>&1
}

teardown() {
  rm -rf "$TMPDIR_TEST"
  if [[ -f "$REPO_ROOT/.runtime-data-dir.bak" ]]; then
    mv "$REPO_ROOT/.runtime-data-dir.bak" "$REPO_ROOT/.runtime-data-dir"
  else
    rm -f "$REPO_ROOT/.runtime-data-dir"
  fi
}

@test "stop hook with no DB exits 0 silently" {
  rm -f "$TMPDIR_TEST/goals.db"
  INPUT='{"session_id":"s1","transcript_path":"/dev/null","stop_hook_active":false}'
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/stop.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stop hook with malformed JSON exits 0 silently" {
  run bash -c "echo 'not json at all' | $REPO_ROOT/scripts/stop.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "post-tool-batch with missing transcript exits 0" {
  NOW=$(python3 -c "import time; print(int(time.time()*1000))")
  sqlite3 "$TMPDIR_TEST/goals.db" "INSERT INTO goals (session_id, goal_id, objective, status, resume_at_ms, created_at_ms, updated_at_ms) VALUES ('s1', 'g1', 'x', 'active', $NOW, $NOW, $NOW);"
  INPUT='{"session_id":"s1","transcript_path":"/this/path/does/not/exist","tool_calls":[]}'
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/post-tool-batch.sh"
  [ "$status" -eq 0 ]
}

@test "stop hook emits systemMessage on DB corruption" {
  echo "GARBAGE NOT SQLITE" > "$DB_PATH"
  INPUT='{"session_id":"s1","transcript_path":"/dev/null","stop_hook_active":false}'
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/stop.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"systemMessage"* ]]
  echo "$output" | jq -e '.systemMessage' >/dev/null
}
