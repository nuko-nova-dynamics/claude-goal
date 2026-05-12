#!/usr/bin/env bats

setup() {
  TMPDIR_TEST=$(mktemp -d)
  export CLAUDE_PLUGIN_DATA="$TMPDIR_TEST"
  export DB_PATH="$TMPDIR_TEST/goals.db"
  export CLAUDE_PLUGIN_ROOT="$TMPDIR_TEST/plugin-root"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export REPO_ROOT
  mkdir -p "$CLAUDE_PLUGIN_ROOT"
  "$REPO_ROOT/tests/helpers/init-test-db.sh" "$DB_PATH" >/dev/null
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

@test "statusline safely handles quoted session ids" {
  NOW=$(python3 -c "import time; print(int(time.time()*1000))")
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, tokens_used, token_budget, created_at_ms, updated_at_ms)
    VALUES ('s''1', 'g1', 'quoted session', 'active', 1200, 5000, $NOW, $NOW);"

  export CLAUDE_SESSION_ID="s'1"
  run "$REPO_ROOT/statusline/status.sh"

  [ "$status" -eq 0 ]
  [ "$output" = "◎ goal active (1K / 5K)" ]
}
