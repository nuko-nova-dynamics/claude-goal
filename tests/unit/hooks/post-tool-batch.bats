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
  "$REPO_ROOT/tests/helpers/init-test-db.sh" "$DB_PATH"
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
  SUBAGENT_TOKENS=$(sqlite3 "$DB_PATH" "SELECT subagent_tokens FROM goals WHERE session_id='s1';")
  [ "$SUBAGENT_TOKENS" = "0" ]
}

@test "post-tool-batch with agent_id updates subagent_tokens from agent_transcript_path" {
  AGENT_TRANSCRIPT="$TMPDIR_TEST/agent-a1.jsonl"
  cat > "$AGENT_TRANSCRIPT" <<'EOF'
{"type":"assistant","uuid":"a1","message":{"usage":{"input_tokens":20,"output_tokens":7}}}
EOF
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"agent_id\":\"a1\",\"agent_transcript_path\":\"$AGENT_TRANSCRIPT\",\"tool_calls\":[]}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/post-tool-batch.sh"
  [ "$status" -eq 0 ]
  ROW=$(sqlite3 "$DB_PATH" "SELECT tokens_used || '|' || subagent_tokens FROM goals WHERE session_id='s1';")
  [ "$ROW" = "0|27" ]
}

@test "post-tool-batch with agent_id skips accounting when subagent transcript is missing" {
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"agent_id\":\"missing-agent\",\"tool_calls\":[]}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/post-tool-batch.sh"
  [ "$status" -eq 0 ]

  ROW=$(sqlite3 "$DB_PATH" "SELECT tokens_used || '|' || subagent_tokens FROM goals WHERE session_id='s1';")
  [ "$ROW" = "0|0" ]
  CURSORS=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM subagent_token_cursors WHERE session_id='s1';")
  [ "$CURSORS" = "0" ]
  EVENTS=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM goal_events WHERE session_id='s1' AND event_type='tokens_accounted';")
  [ "$EVENTS" = "0" ]
}

@test "post-tool-batch mixed parent and subagent batches accumulate independently" {
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"tool_calls\":[]}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/post-tool-batch.sh"
  [ "$status" -eq 0 ]

  AGENT_TRANSCRIPT="$TMPDIR_TEST/agent-a2.jsonl"
  cat > "$AGENT_TRANSCRIPT" <<'EOF'
{"type":"assistant","uuid":"a1","message":{"usage":{"input_tokens":3,"output_tokens":4}}}
EOF
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"agent_id\":\"a2\",\"agent_transcript_path\":\"$AGENT_TRANSCRIPT\",\"tool_calls\":[]}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/post-tool-batch.sh"
  [ "$status" -eq 0 ]

  echo '{"type":"assistant","uuid":"u3","message":{"usage":{"input_tokens":5,"output_tokens":6}}}' >> "$TRANSCRIPT"
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"tool_calls\":[]}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/post-tool-batch.sh"
  [ "$status" -eq 0 ]

  ROW=$(sqlite3 "$DB_PATH" "SELECT tokens_used || '|' || subagent_tokens FROM goals WHERE session_id='s1';")
  [ "$ROW" = "26|7" ]
}

@test "post-tool-batch is no-op for missing goal" {
  rm "$DB_PATH"
  "$REPO_ROOT/tests/helpers/init-test-db.sh" "$DB_PATH"
  INPUT="{\"session_id\":\"absent\",\"transcript_path\":\"$TRANSCRIPT\",\"tool_calls\":[]}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/post-tool-batch.sh"
  [ "$status" -eq 0 ]
}

@test "post-tool-batch skips all DB work when sessions dir exists without a marker" {
  mkdir -p "$TMPDIR_TEST/sessions"
  # No marker for s1 → hook must exit before accounting.
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"tool_calls\":[]}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/post-tool-batch.sh"
  [ "$status" -eq 0 ]
  TOKENS=$(sqlite3 "$DB_PATH" "SELECT tokens_used FROM goals WHERE session_id='s1';")
  [ "$TOKENS" = "0" ]
}

@test "post-tool-batch accounts normally when the session marker exists" {
  mkdir -p "$TMPDIR_TEST/sessions"
  touch "$TMPDIR_TEST/sessions/s1"
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"tool_calls\":[]}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/post-tool-batch.sh"
  [ "$status" -eq 0 ]
  TOKENS=$(sqlite3 "$DB_PATH" "SELECT tokens_used FROM goals WHERE session_id='s1';")
  [ "$TOKENS" = "15" ]
}

@test "post-tool-batch sanitizes hostile session ids for the marker path" {
  mkdir -p "$TMPDIR_TEST/sessions"
  # Slashes are replaced with underscores, so the lookup cannot escape sessions/.
  touch "$TMPDIR_TEST/sessions/.._.._.._etc_passwd"
  INPUT="{\"session_id\":\"../../../etc/passwd\",\"transcript_path\":\"$TRANSCRIPT\",\"tool_calls\":[]}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/post-tool-batch.sh"
  [ "$status" -eq 0 ]
}
