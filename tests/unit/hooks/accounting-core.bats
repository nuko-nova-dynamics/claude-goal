#!/usr/bin/env bats

setup() {
  TMPDIR_TEST=$(mktemp -d)
  export DB_PATH="$TMPDIR_TEST/g.db"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  "$REPO_ROOT/tests/helpers/init-test-db.sh" "$DB_PATH"
  # Cross-platform milliseconds
  NOW_MS=$(python3 -c "import time; print(int(time.time()*1000))")
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, resume_at_ms, created_at_ms, updated_at_ms)
    VALUES ('s1', 'g1', 'x', 'active', $NOW_MS, $NOW_MS, $NOW_MS);"
  source "$REPO_ROOT/scripts/lib/sqlite-retry.sh"
  source "$REPO_ROOT/scripts/lib/accounting-core.sh"

  export TRANSCRIPT="$TMPDIR_TEST/t.jsonl"
  cat > "$TRANSCRIPT" <<'EOF'
{"type":"user","uuid":"u1","message":{"content":[]}}
{"type":"assistant","uuid":"u2","message":{"usage":{"input_tokens":10,"output_tokens":5}}}
{"type":"assistant","uuid":"u3","message":{"usage":{"input_tokens":20,"cache_creation_input_tokens":100,"output_tokens":15}}}
EOF
}

teardown() { rm -rf "$TMPDIR_TEST"; }

@test "advance() sums tokens and updates cursor" {
  account_advance_inline "s1" "$TRANSCRIPT"
  TOKENS=$(sqlite3 "$DB_PATH" "SELECT tokens_used FROM goals WHERE session_id='s1';")
  [ "$TOKENS" = "150" ]   # 10+5 + 20+100+15
  UUID=$(sqlite3 "$DB_PATH" "SELECT last_accounted_uuid FROM goals WHERE session_id='s1';")
  [ "$UUID" = "u3" ]
}

@test "advance() is idempotent when transcript has no new content" {
  account_advance_inline "s1" "$TRANSCRIPT"
  BEFORE=$(sqlite3 "$DB_PATH" "SELECT last_accounted_uuid || '|' || last_accounted_byte_offset || '|' || tokens_used || '|' || version FROM goals WHERE session_id='s1';")
  EVENTS_BEFORE=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM goal_events WHERE session_id='s1' AND event_type='tokens_accounted';")

  account_advance_inline "s1" "$TRANSCRIPT"

  AFTER=$(sqlite3 "$DB_PATH" "SELECT last_accounted_uuid || '|' || last_accounted_byte_offset || '|' || tokens_used || '|' || version FROM goals WHERE session_id='s1';")
  EVENTS_AFTER=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM goal_events WHERE session_id='s1' AND event_type='tokens_accounted';")
  [ "$AFTER" = "$BEFORE" ]
  [ "$EVENTS_BEFORE" = "1" ]
  [ "$EVENTS_AFTER" = "1" ]
}

@test "sum_transcript accounts final JSONL record without trailing newline" {
  printf '%s' '{"type":"assistant","uuid":"u1","message":{"usage":{"input_tokens":5,"output_tokens":7}}}' > "$TRANSCRIPT"
  RESULT=$(sum_transcript "$TRANSCRIPT" 0 "")
  IFS='|' read -r TOKENS UUID END_OFFSET CURSOR_RESET CAP_FIELD <<< "$RESULT"
  [ "$TOKENS" = "12" ]
  [ "$UUID" = "u1" ]
  [ "$CURSOR_RESET" = "0" ]
}

@test "sum_transcript validates previous uuid when prefix lacks trailing newline" {
  printf '%s' '{"type":"assistant","uuid":"u1","message":{"usage":{"input_tokens":5,"output_tokens":7}}}' > "$TRANSCRIPT"
  OFFSET=$(wc -c < "$TRANSCRIPT" | tr -d ' ')
  RESULT=$(sum_transcript "$TRANSCRIPT" "$OFFSET" "u1")
  IFS='|' read -r TOKENS UUID END_OFFSET CURSOR_RESET CAP_FIELD <<< "$RESULT"
  [ "$TOKENS" = "0" ]
  [ "$CURSOR_RESET" = "0" ]
}

@test "advance() with append: adds delta" {
  account_advance_inline "s1" "$TRANSCRIPT"
  echo '{"type":"assistant","uuid":"u4","message":{"usage":{"input_tokens":5,"output_tokens":5}}}' >> "$TRANSCRIPT"
  account_advance_inline "s1" "$TRANSCRIPT"
  TOKENS=$(sqlite3 "$DB_PATH" "SELECT tokens_used FROM goals WHERE session_id='s1';")
  [ "$TOKENS" = "160" ]
  UNCERTAIN=$(sqlite3 "$DB_PATH" "SELECT accounting_uncertain FROM goals WHERE session_id='s1';")
  [ "$UNCERTAIN" = "0" ]
  SECOND_DELTA=$(sqlite3 "$DB_PATH" "SELECT tokens_delta FROM goal_events WHERE session_id='s1' AND event_type='tokens_accounted' ORDER BY id LIMIT 1 OFFSET 1;")
  [ "$SECOND_DELTA" = "10" ]
}

@test "advance() can catch late final tokens after goal is already complete" {
  cat > "$TRANSCRIPT" <<'EOF'
{"type":"user","uuid":"u0","message":{"content":[]}}
{"type":"assistant","uuid":"u1","message":{"usage":{"input_tokens":100,"output_tokens":50},"content":[{"type":"tool_use","name":"update_goal","input":{"status":"complete"}}]}}
EOF
  sqlite3 "$DB_PATH" "UPDATE goals SET status='complete', token_budget=100, tokens_used=0, last_accounted_byte_offset=0, last_accounted_uuid=NULL WHERE session_id='s1';"

  account_advance_inline "s1" "$TRANSCRIPT"

  ROW=$(sqlite3 "$DB_PATH" "SELECT status || '|' || tokens_used || '|' || last_accounted_uuid FROM goals WHERE session_id='s1';")
  [ "$ROW" = "complete|150|u1" ]
}

@test "advance() can catch late final tokens after goal is already blocked" {
  cat > "$TRANSCRIPT" <<'EOF'
{"type":"user","uuid":"u0","message":{"content":[]}}
{"type":"assistant","uuid":"u1","message":{"usage":{"input_tokens":100,"output_tokens":50},"content":[{"type":"tool_use","name":"update_goal","input":{"status":"blocked","blocked_reason":"needs credentials"}}]}}
EOF
  sqlite3 "$DB_PATH" "UPDATE goals SET status='blocked', token_budget=100, tokens_used=0, last_accounted_byte_offset=0, last_accounted_uuid=NULL WHERE session_id='s1';"

  account_advance_inline "s1" "$TRANSCRIPT"

  ROW=$(sqlite3 "$DB_PATH" "SELECT status || '|' || tokens_used || '|' || last_accounted_uuid FROM goals WHERE session_id='s1';")
  [ "$ROW" = "blocked|150|u1" ]
}

@test "advance() on append with cursor uuid mismatch marks accounting uncertain" {
  account_advance_inline "s1" "$TRANSCRIPT"
  cat > "$TRANSCRIPT" <<'EOF'
{"type":"user","uuid":"u1","message":{"content":[]}}
{"type":"assistant","uuid":"REWRITTEN","message":{"usage":{"input_tokens":20,"output_tokens":5}}}
{"type":"assistant","uuid":"u3","message":{"usage":{"input_tokens":20,"cache_creation_input_tokens":100,"output_tokens":15}}}
{"type":"assistant","uuid":"u4","message":{"usage":{"input_tokens":5,"output_tokens":5}}}
EOF
  account_advance_inline "s1" "$TRANSCRIPT"
  UNCERTAIN=$(sqlite3 "$DB_PATH" "SELECT accounting_uncertain FROM goals WHERE session_id='s1';")
  [ "$UNCERTAIN" = "1" ]
}

@test "advance() on cursor reset: takes MAX (monotonic)" {
  account_advance_inline "s1" "$TRANSCRIPT"
  # Replace transcript with shorter version (simulates /compact summary)
  cat > "$TRANSCRIPT" <<'EOF'
{"type":"assistant","uuid":"NEW","message":{"usage":{"input_tokens":1,"output_tokens":1}}}
EOF
  account_advance_inline "s1" "$TRANSCRIPT"
  TOKENS=$(sqlite3 "$DB_PATH" "SELECT tokens_used FROM goals WHERE session_id='s1';")
  UNCERTAIN=$(sqlite3 "$DB_PATH" "SELECT accounting_uncertain FROM goals WHERE session_id='s1';")
  [ "$TOKENS" = "150" ]   # MAX(150 prior, 2 recomputed)
  [ "$UNCERTAIN" = "1" ]
}

@test "advance() triggers budget_limited transition" {
  sqlite3 "$DB_PATH" "UPDATE goals SET token_budget = 100 WHERE session_id='s1';"
  account_advance_inline "s1" "$TRANSCRIPT"
  STATUS=$(sqlite3 "$DB_PATH" "SELECT status FROM goals WHERE session_id='s1';")
  [ "$STATUS" = "budget_limited" ]
}

@test "advance() with agent_id uses subagent_tokens and separate cursor" {
  AGENT_TRANSCRIPT="$TMPDIR_TEST/agent.jsonl"
  cat > "$AGENT_TRANSCRIPT" <<'EOF'
{"type":"assistant","uuid":"a1","message":{"usage":{"input_tokens":8,"output_tokens":2}}}
EOF

  account_advance_inline "s1" "$AGENT_TRANSCRIPT" "agent-1"

  ROW=$(sqlite3 "$DB_PATH" "SELECT tokens_used || '|' || subagent_tokens || '|' || last_accounted_byte_offset FROM goals WHERE session_id='s1';")
  [ "$ROW" = "0|10|0" ]

  echo '{"type":"assistant","uuid":"a2","message":{"usage":{"input_tokens":5,"output_tokens":1}}}' >> "$AGENT_TRANSCRIPT"
  account_advance_inline "s1" "$AGENT_TRANSCRIPT" "agent-1"

  SUBAGENT_TOKENS=$(sqlite3 "$DB_PATH" "SELECT subagent_tokens FROM goals WHERE session_id='s1';")
  [ "$SUBAGENT_TOKENS" = "16" ]
}

@test "advance() budget includes parent and subagent tokens" {
  sqlite3 "$DB_PATH" "UPDATE goals SET token_budget = 20, tokens_used = 15 WHERE session_id='s1';"
  AGENT_TRANSCRIPT="$TMPDIR_TEST/agent-budget.jsonl"
  cat > "$AGENT_TRANSCRIPT" <<'EOF'
{"type":"assistant","uuid":"a1","message":{"usage":{"input_tokens":4,"output_tokens":2}}}
EOF

  account_advance_inline "s1" "$AGENT_TRANSCRIPT" "agent-1"

  STATUS=$(sqlite3 "$DB_PATH" "SELECT status FROM goals WHERE session_id='s1';")
  [ "$STATUS" = "budget_limited" ]
}

@test "advance() pauses on input_tokens cap exceeded" {
  cat > "$TRANSCRIPT" <<'EOF'
{"type":"assistant","uuid":"u1","message":{"usage":{"input_tokens":300000,"output_tokens":0}}}
EOF
  account_advance_inline "s1" "$TRANSCRIPT"
  STATUS=$(sqlite3 "$DB_PATH" "SELECT status || '|' || paused_reason FROM goals WHERE session_id='s1';")
  [ "$STATUS" = "paused|accounting_error" ]
}

@test "advance() pauses on output_tokens cap exceeded" {
  cat > "$TRANSCRIPT" <<'EOF'
{"type":"assistant","uuid":"u1","message":{"usage":{"input_tokens":0,"output_tokens":150000}}}
EOF
  account_advance_inline "s1" "$TRANSCRIPT"
  STATUS=$(sqlite3 "$DB_PATH" "SELECT status || '|' || paused_reason FROM goals WHERE session_id='s1';")
  [ "$STATUS" = "paused|accounting_error" ]
}

@test "advance() pauses on cache_creation_input_tokens cap exceeded" {
  cat > "$TRANSCRIPT" <<'EOF'
{"type":"assistant","uuid":"u1","message":{"usage":{"input_tokens":0,"cache_creation_input_tokens":250000,"output_tokens":0}}}
EOF
  account_advance_inline "s1" "$TRANSCRIPT"
  STATUS=$(sqlite3 "$DB_PATH" "SELECT status || '|' || paused_reason FROM goals WHERE session_id='s1';")
  [ "$STATUS" = "paused|accounting_error" ]
}
