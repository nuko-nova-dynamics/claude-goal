#!/usr/bin/env bats

setup() {
  TMPDIR_TEST=$(mktemp -d)
  # The script resolves DB_PATH as $CLAUDE_PLUGIN_DATA/goals.db, so use that name.
  export CLAUDE_PLUGIN_DATA="$TMPDIR_TEST"
  export DB_PATH="$TMPDIR_TEST/goals.db"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export REPO_ROOT
  # Unset CLAUDE_PLUGIN_ROOT so the script falls back to CLAUDE_PLUGIN_DATA env
  # (which we control via TMPDIR_TEST), rather than reading the real marker file.
  unset CLAUDE_PLUGIN_ROOT
  sqlite3 "$DB_PATH" < "$REPO_ROOT/mcp/goal-server/src/migrations/001_initial.sql"
  # Cross-platform milliseconds (macOS lacks date +%s%3N)
  NOW_MS=$(python3 -c "import time; print(int(time.time()*1000))")
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, resume_at_ms, created_at_ms, updated_at_ms)
    VALUES ('s1', 'g1', 'x', 'active', $NOW_MS, $NOW_MS, $NOW_MS);"

  export TRANSCRIPT="$TMPDIR_TEST/t.jsonl"
  cat > "$TRANSCRIPT" <<'EOF'
{"type":"assistant","uuid":"u2","message":{"usage":{"input_tokens":10,"output_tokens":5}}}
EOF
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

@test "post-tool-batch updates tokens_used" {
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"tool_calls\":[]}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/post-tool-batch.sh"
  [ "$status" -eq 0 ]
  TOKENS=$(sqlite3 "$DB_PATH" "SELECT tokens_used FROM goals WHERE session_id='s1';")
  [ "$TOKENS" = "15" ]
}

@test "post-tool-batch is no-op for missing goal" {
  rm "$DB_PATH"
  sqlite3 "$DB_PATH" < "$REPO_ROOT/mcp/goal-server/src/migrations/001_initial.sql"
  INPUT="{\"session_id\":\"absent\",\"transcript_path\":\"$TRANSCRIPT\",\"tool_calls\":[]}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/post-tool-batch.sh"
  [ "$status" -eq 0 ]
}
