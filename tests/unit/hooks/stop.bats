#!/usr/bin/env bats

setup() {
  TMPDIR_TEST=$(mktemp -d)
  # Script always writes $PLUGIN_DATA/goals.db; match the filename the script will use.
  export DB_PATH="$TMPDIR_TEST/goals.db"
  export CLAUDE_PLUGIN_DATA="$TMPDIR_TEST"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export REPO_ROOT
  export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"

  # Override the .runtime-data-dir marker so the DB resolver uses our TMPDIR_TEST,
  # not the real plugin data dir. Save and restore in teardown.
  if [[ -f "$REPO_ROOT/.runtime-data-dir" ]]; then
    cp "$REPO_ROOT/.runtime-data-dir" "$REPO_ROOT/.runtime-data-dir.bak"
  fi
  printf '%s' "$TMPDIR_TEST" > "$REPO_ROOT/.runtime-data-dir"

  sqlite3 "$DB_PATH" < "$REPO_ROOT/mcp/goal-server/src/migrations/001_initial.sql" >/dev/null 2>&1
  # Cross-platform milliseconds (macOS lacks date +%s%3N)
  NOW=$(python3 -c "import time; print(int(time.time()*1000))")
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, token_budget, tokens_used, resume_at_ms, created_at_ms, updated_at_ms)
    VALUES ('s1', 'g1', 'ship it', 'active', 10000, 1000, $NOW, $NOW, $NOW);"
  export TRANSCRIPT="$TMPDIR_TEST/t.jsonl"
  echo "" > "$TRANSCRIPT"
}

teardown() {
  # Restore the marker file
  if [[ -f "$REPO_ROOT/.runtime-data-dir.bak" ]]; then
    mv "$REPO_ROOT/.runtime-data-dir.bak" "$REPO_ROOT/.runtime-data-dir"
  else
    rm -f "$REPO_ROOT/.runtime-data-dir"
  fi
  rm -rf "$TMPDIR_TEST"
}

@test "stop hook injects continuation block-decision when active" {
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"stop_hook_active\":false}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/stop.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"decision":"block"'* ]]
  [[ "$output" == *"ship it"* ]]
  REM=$(sqlite3 "$DB_PATH" "SELECT continuations_remaining FROM goals;")
  [ "$REM" = "49" ]
}

@test "stop hook is silent when status=complete" {
  sqlite3 "$DB_PATH" "UPDATE goals SET status='complete' WHERE session_id='s1';"
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"stop_hook_active\":false}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/stop.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stop hook recursion-guard short-circuits on stop_hook_active=true" {
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"stop_hook_active\":true}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/stop.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stop hook flips to paused on continuation_cap" {
  sqlite3 "$DB_PATH" "UPDATE goals SET continuations_remaining=0 WHERE session_id='s1';"
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"stop_hook_active\":false}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/stop.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  ROW=$(sqlite3 "$DB_PATH" "SELECT status, paused_reason FROM goals;")
  [[ "$ROW" == "paused|continuation_cap" ]]
}

@test "stop hook injects budget-limit one-shot when budget_limited" {
  sqlite3 "$DB_PATH" "UPDATE goals SET status='budget_limited', budget_limit_reported=0 WHERE session_id='s1';"
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"stop_hook_active\":false}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/stop.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"decision":"block"'* ]]
  [[ "$output" == *"reached its token budget"* ]]
  REPORTED=$(sqlite3 "$DB_PATH" "SELECT budget_limit_reported FROM goals;")
  [ "$REPORTED" = "1" ]
}

@test "stop hook silent on second budget_limited fire" {
  sqlite3 "$DB_PATH" "UPDATE goals SET status='budget_limited', budget_limit_reported=1 WHERE session_id='s1';"
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"stop_hook_active\":false}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/stop.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stop hook detects update_goal in transcript and skips injection" {
  # Verified via docs check: Stop hook stdin does NOT contain tool_calls.
  # Detection works by reading the transcript JSONL for the most recent
  # assistant message and checking its tool_use blocks for update_goal.
  cat > "$TRANSCRIPT" <<'EOF'
{"type":"assistant","uuid":"u1","message":{"content":[{"type":"text","text":"done"},{"type":"tool_use","name":"update_goal","input":{"status":"complete"}}]}}
EOF
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"stop_hook_active\":false}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/stop.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stop hook releases lease after injection" {
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"stop_hook_active\":false}"
  bash -c "echo '$INPUT' | $REPO_ROOT/scripts/stop.sh" >/dev/null
  # Lease should not exist (released after successful injection)
  COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM continuation_leases WHERE session_id='s1';")
  [ "$COUNT" = "0" ]
}

@test "stop hook escapes single quotes in objective" {
  sqlite3 "$DB_PATH" "UPDATE goals SET objective='it''s a goal with \"quotes\"' WHERE session_id='s1';"
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"stop_hook_active\":false}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/stop.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"decision":"block"'* ]]
  # Reason field should contain the objective content; SQL injection blocked
  echo "$output" | jq -e '.reason | test("it.s a goal")' >/dev/null
}
