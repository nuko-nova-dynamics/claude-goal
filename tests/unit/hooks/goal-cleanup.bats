#!/usr/bin/env bats

setup() {
  TMPDIR_TEST=$(mktemp -d)
  export CLAUDE_PLUGIN_DATA="$TMPDIR_TEST"
  export DB_PATH="$TMPDIR_TEST/goals.db"
  export CLAUDE_SESSION_ID="any"  # cleanup doesn't need it but goal-cli's resolver may want a value
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export REPO_ROOT
  CLI="$REPO_ROOT/scripts/goal-cli.sh"
  export CLI
  # Isolate from real marker file
  [[ -f "$REPO_ROOT/.runtime-data-dir" ]] && cp "$REPO_ROOT/.runtime-data-dir" "$REPO_ROOT/.runtime-data-dir.bak"
  printf '%s' "$TMPDIR_TEST" > "$REPO_ROOT/.runtime-data-dir"
  "$REPO_ROOT/tests/helpers/init-test-db.sh" "$DB_PATH"
  NOW=$(python3 -c "import time; print(int(time.time()*1000))")
  STALE=$(( NOW - (48 * 3600 * 1000) ))
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, created_at_ms, updated_at_ms) VALUES ('stale-sess', 'g-stale', 'old goal', 'active', $STALE, $STALE);"
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, created_at_ms, updated_at_ms) VALUES ('fresh-sess', 'g-fresh', 'recent goal', 'active', $NOW, $NOW);"
}
teardown() {
  rm -rf "$TMPDIR_TEST"
  if [[ -f "$REPO_ROOT/.runtime-data-dir.bak" ]]; then
    mv "$REPO_ROOT/.runtime-data-dir.bak" "$REPO_ROOT/.runtime-data-dir"
  else
    rm -f "$REPO_ROOT/.runtime-data-dir"
  fi
}

@test "cleanup --list --older-than 24 shows only stale goals" {
  run "$CLI" cleanup --list --older-than 24
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale-sess"* ]]
  [[ "$output" != *"fresh-sess"* ]]
}

@test "cleanup --delete --older-than 24 removes stale goals" {
  run "$CLI" cleanup --delete --older-than 24
  [ "$status" -eq 0 ]
  COUNT_STALE=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM goals WHERE session_id='stale-sess';")
  COUNT_FRESH=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM goals WHERE session_id='fresh-sess';")
  [ "$COUNT_STALE" = "0" ]
  [ "$COUNT_FRESH" = "1" ]
}

@test "cleanup requires --list or --delete" {
  run "$CLI" cleanup
  [ "$status" -eq 1 ]
}

@test "cleanup --list with no --older-than shows fresh orphans (default 0)" {
  run "$CLI" cleanup --list
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale-sess"* ]]
  [[ "$output" == *"fresh-sess"* ]]
}

@test "cleanup --delete with no --older-than preserves fresh goals (default 24)" {
  run "$CLI" cleanup --delete
  [ "$status" -eq 0 ]
  COUNT_FRESH=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM goals WHERE session_id='fresh-sess';")
  [ "$COUNT_FRESH" = "1" ]
}
