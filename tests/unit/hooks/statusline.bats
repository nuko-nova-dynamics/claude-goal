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

@test "statusline formats million-scale budgets with M suffix" {
  NOW=$(python3 -c "import time; print(int(time.time()*1000))")
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, tokens_used, token_budget, created_at_ms, updated_at_ms)
    VALUES ('sM', 'gM', 'million-scale goal', 'active', 1200000, 5000000, $NOW, $NOW);"

  export CLAUDE_SESSION_ID="sM"
  run "$REPO_ROOT/statusline/status.sh"

  [ "$status" -eq 0 ]
  [ "$output" = "◎ goal active (1.2M / 5M)" ]
}

@test "statusline includes subagent tokens in displayed total" {
  NOW=$(python3 -c "import time; print(int(time.time()*1000))")
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, tokens_used, subagent_tokens, token_budget, created_at_ms, updated_at_ms)
    VALUES ('s-total', 'g-total', 'total goal', 'active', 1200, 800, 5000, $NOW, $NOW);"

  export CLAUDE_SESSION_ID="s-total"
  run "$REPO_ROOT/statusline/status.sh"

  [ "$status" -eq 0 ]
  [ "$output" = "◎ goal active (2K / 5K)" ]
}

@test "statusline shows integer M when divisible" {
  NOW=$(python3 -c "import time; print(int(time.time()*1000))")
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, tokens_used, token_budget, created_at_ms, updated_at_ms)
    VALUES ('sM2', 'gM2', 'exact M', 'active', 2000000, 10000000, $NOW, $NOW);"

  export CLAUDE_SESSION_ID="sM2"
  run "$REPO_ROOT/statusline/status.sh"

  [ "$status" -eq 0 ]
  [ "$output" = "◎ goal active (2M / 10M)" ]
}

@test "statusline shows blocked status" {
  NOW=$(python3 -c "import time; print(int(time.time()*1000))")
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, created_at_ms, updated_at_ms)
    VALUES ('s-blocked', 'g-blocked', 'blocked goal', 'blocked', $NOW, $NOW);"

  export CLAUDE_SESSION_ID="s-blocked"
  run "$REPO_ROOT/statusline/status.sh"

  [ "$status" -eq 0 ]
  [ "$output" = "◎ goal blocked" ]
}
