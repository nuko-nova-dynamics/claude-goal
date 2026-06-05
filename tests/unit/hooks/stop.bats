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

  "$REPO_ROOT/tests/helpers/init-test-db.sh" "$DB_PATH" >/dev/null 2>&1
  # Cross-platform milliseconds (macOS lacks date +%s%3N)
  NOW=$(python3 -c "import time; print(int(time.time()*1000))")
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, token_budget, tokens_used, resume_at_ms, created_at_ms, updated_at_ms)
    VALUES ('s1', 'g1', 'ship it', 'active', 10000, 1000, $NOW, $NOW, $NOW);"
  export TRANSCRIPT="$TMPDIR_TEST/t.jsonl"
  echo "" > "$TRANSCRIPT"
}

hash_text() {
  printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
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
  REASON=$(echo "$output" | jq -r '.reason')
  [[ "$REASON" == *"claude-goal:goal-evaluator"* ]]
  [[ "$REASON" == *"session_id: s1"* ]]
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

@test "stop hook is silent when status=blocked" {
  sqlite3 "$DB_PATH" "UPDATE goals SET status='blocked' WHERE session_id='s1';"
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"stop_hook_active\":false}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/stop.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  REM=$(sqlite3 "$DB_PATH" "SELECT continuations_remaining FROM goals WHERE session_id='s1';")
  [ "$REM" = "50" ]
}

@test "stop hook recursion-guard short-circuits when stop_hook_active=true and no new assistant turn" {
  cat > "$TRANSCRIPT" <<'EOF'
{"type":"assistant","uuid":"u1","message":{"usage":{"input_tokens":1,"cache_creation_input_tokens":0,"output_tokens":1},"content":[{"type":"text","text":"done for now"}]}}
EOF
  HASH=$(hash_text "done for now")
  sqlite3 "$DB_PATH" "UPDATE goals SET last_accounted_uuid='u1' WHERE session_id='s1';"
  sqlite3 "$DB_PATH" "INSERT INTO goal_events (session_id, goal_id, hook_name, event_type, decision, payload_json, created_at_ms)
    VALUES ('s1', 'g1', 'stop', 'continuation_injected', 'block', '{\"assistant_uuid\":\"u1\",\"assistant_message_hash\":\"$HASH\"}', $NOW);"
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"stop_hook_active\":true,\"last_assistant_message\":\"done for now\"}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/stop.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stop hook still injects on stop_hook_active=true after continuation turn advances transcript" {
  cat > "$TRANSCRIPT" <<'EOF'
{"type":"assistant","uuid":"u2","message":{"usage":{"input_tokens":1,"cache_creation_input_tokens":0,"output_tokens":1},"content":[{"type":"text","text":"continuation turn finished"}]}}
EOF
  HASH=$(hash_text "previous turn")
  sqlite3 "$DB_PATH" "UPDATE goals SET last_accounted_uuid='u2', last_continuation_at_ms=1 WHERE session_id='s1';"
  sqlite3 "$DB_PATH" "INSERT INTO goal_events (session_id, goal_id, hook_name, event_type, decision, payload_json, created_at_ms)
    VALUES ('s1', 'g1', 'stop', 'continuation_injected', 'block', '{\"assistant_uuid\":\"u1\",\"assistant_message_hash\":\"$HASH\"}', $NOW);"
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"stop_hook_active\":true,\"last_assistant_message\":\"continuation turn finished\"}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/stop.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"decision":"block"'* ]]
  REM=$(sqlite3 "$DB_PATH" "SELECT continuations_remaining FROM goals;")
  [ "$REM" = "49" ]
  EVENTS=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM goal_events WHERE event_type='continuation_injected' AND json_extract(payload_json, '$.assistant_uuid')='u2';")
  [ "$EVENTS" = "1" ]
}

@test "stop hook still injects when hook assistant message advances before transcript flush" {
  cat > "$TRANSCRIPT" <<'EOF'
{"type":"assistant","uuid":"u1","message":{"usage":{"input_tokens":1,"cache_creation_input_tokens":0,"output_tokens":1},"content":[{"type":"text","text":"1"}]}}
EOF
  HASH=$(hash_text "1")
  sqlite3 "$DB_PATH" "UPDATE goals SET last_accounted_uuid='u1', last_continuation_at_ms=1 WHERE session_id='s1';"
  sqlite3 "$DB_PATH" "INSERT INTO goal_events (session_id, goal_id, hook_name, event_type, decision, payload_json, created_at_ms)
    VALUES ('s1', 'g1', 'stop', 'continuation_injected', 'block', '{\"assistant_uuid\":\"u1\",\"assistant_message_hash\":\"$HASH\"}', $NOW);"
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"stop_hook_active\":true,\"last_assistant_message\":\"2\"}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/stop.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"decision":"block"'* ]]
  REM=$(sqlite3 "$DB_PATH" "SELECT continuations_remaining FROM goals;")
  [ "$REM" = "49" ]
  NEW_HASH=$(hash_text "2")
  EVENTS=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM goal_events WHERE event_type='continuation_injected' AND json_extract(payload_json, '$.assistant_message_hash')='$NEW_HASH';")
  [ "$EVENTS" = "1" ]
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

@test "stop hook flips to paused on wall_clock_cap and records event" {
  PAST=$((NOW - 5000))
  sqlite3 "$DB_PATH" "UPDATE goals SET resume_at_ms=$PAST, max_wall_clock_seconds=1 WHERE session_id='s1';"
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"stop_hook_active\":false}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/stop.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  ROW=$(sqlite3 "$DB_PATH" "SELECT status, paused_reason FROM goals;")
  [[ "$ROW" == "paused|wall_clock_cap" ]]
  EVENTS=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM goal_events WHERE event_type='cap_reached' AND status_before='active' AND status_after='paused';")
  [ "$EVENTS" = "1" ]
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
  EVENTS=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM goal_events WHERE event_type='budget_limit_reported' AND status_before='budget_limited' AND status_after='budget_limited' AND decision='block';")
  [ "$EVENTS" = "1" ]
}

@test "stop hook silent on second budget_limited fire" {
  sqlite3 "$DB_PATH" "UPDATE goals SET status='budget_limited', budget_limit_reported=1 WHERE session_id='s1';"
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"stop_hook_active\":false}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/stop.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stop hook detects namespaced update_goal in last three assistant messages and skips injection" {
  cat > "$TRANSCRIPT" <<'EOF'
{"type":"assistant","uuid":"u1","message":{"content":[{"type":"text","text":"preparing final update"}]}}
{"type":"assistant","uuid":"u2","message":{"content":[{"type":"tool_use","name":"mcp__plugin_claude-goal_goal__update_goal","input":{"status":"complete"}}]}}
{"type":"assistant","uuid":"u3","message":{"content":[{"type":"text","text":"completion tool call was issued"}]}}
EOF
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"stop_hook_active\":false}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/stop.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  REM=$(sqlite3 "$DB_PATH" "SELECT continuations_remaining FROM goals;")
  [ "$REM" = "50" ]
}

@test "stop hook records budget limit even when update_goal appears in transcript" {
  sqlite3 "$DB_PATH" "UPDATE goals SET status='budget_limited', budget_limit_reported=0 WHERE session_id='s1';"
  cat > "$TRANSCRIPT" <<'EOF'
{"type":"assistant","uuid":"u1","message":{"content":[{"type":"tool_use","name":"mcp__plugin_claude-goal_goal__update_goal","input":{"status":"complete"}}]}}
EOF
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"stop_hook_active\":false}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/stop.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"decision":"block"'* ]]
  REPORTED=$(sqlite3 "$DB_PATH" "SELECT budget_limit_reported FROM goals;")
  [ "$REPORTED" = "1" ]
  EVENTS=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM goal_events WHERE event_type='budget_limit_reported';")
  [ "$EVENTS" = "1" ]
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

@test "F5: completion turn tokens are accounted by the time update_goal is detected" {
  # F5 outcome contract: after stop.sh exits on update_goal detection, the
  # completion turn's tokens must be reflected in tokens_used. The start-of-
  # hook accounting pass (line 122) usually catches them; the F5 retry loop is
  # the safety net for slow transcript flushes.
  cat > "$TRANSCRIPT" <<'EOF'
{"type":"user","uuid":"u0","message":{"role":"user","content":[{"type":"text","text":"go"}]}}
{"type":"assistant","uuid":"u1","message":{"role":"assistant","content":[{"type":"text","text":"done"},{"type":"tool_use","name":"update_goal","input":{"status":"complete"}}],"usage":{"input_tokens":100,"output_tokens":50}}}
EOF
  # Reset accounting cursor: simulate that no prior PostToolBatch has run
  sqlite3 "$DB_PATH" "UPDATE goals SET last_accounted_byte_offset = 0, last_accounted_uuid = NULL, tokens_used = 0 WHERE session_id='s1';"
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"stop_hook_active\":false}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/stop.sh"
  [ "$status" -eq 0 ]
  # The completion turn's tokens (100 + 50 = 150) MUST be accounted by the time
  # stop.sh exits. Whether the start-of-hook pass or the F5 retry caught them
  # is implementation detail; the contract is that no tokens are dropped.
  TOKENS=$(sqlite3 "$DB_PATH" "SELECT tokens_used FROM goals WHERE session_id='s1';")
  [ "$TOKENS" = "150" ]
}

@test "F5: retry loop emits event when it catches a late-flushing transcript" {
  cat > "$TRANSCRIPT" <<'EOF'
{"type":"user","uuid":"u0","message":{"role":"user","content":[{"type":"text","text":"go"}]}}
{"type":"assistant","uuid":"u1","message":{"role":"assistant","content":[{"type":"text","text":"done"},{"type":"tool_use","name":"update_goal","input":{"status":"complete"}}]}}
EOF
  VISIBLE_SIZE=$(stat -f%z "$TRANSCRIPT" 2>/dev/null || stat -c%s "$TRANSCRIPT")
  sqlite3 "$DB_PATH" "UPDATE goals SET last_accounted_byte_offset = $VISIBLE_SIZE, last_accounted_uuid = 'u1', tokens_used = 0 WHERE session_id='s1';"
  # The completion signal is visible, but the usage-bearing final record arrives
  # after the first accounting pass, while stop.sh is in its bounded F5 retry.
  (
    sleep 0.15
    cat >> "$TRANSCRIPT" <<'EOF'
{"type":"assistant","uuid":"u2","message":{"role":"assistant","content":[{"type":"text","text":"tool result observed"}],"usage":{"input_tokens":200,"output_tokens":80}}}
EOF
  ) &
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"stop_hook_active\":false}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/stop.sh"
  wait
  [ "$status" -eq 0 ]
  TOKENS=$(sqlite3 "$DB_PATH" "SELECT tokens_used FROM goals WHERE session_id='s1';")
  [ "$TOKENS" = "280" ]
  EVENTS=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM goal_events WHERE event_type='final_turn_accounted';")
  [ "$EVENTS" = "1" ]
}

@test "F5: completed goal still catches late final-turn tokens" {
  cat > "$TRANSCRIPT" <<'EOF'
{"type":"user","uuid":"u0","message":{"role":"user","content":[{"type":"text","text":"go"}]}}
EOF
  USER_ONLY_SIZE=$(stat -f%z "$TRANSCRIPT" 2>/dev/null || stat -c%s "$TRANSCRIPT")
  sqlite3 "$DB_PATH" "UPDATE goals SET status='complete', last_accounted_byte_offset = $USER_ONLY_SIZE, last_accounted_uuid = 'u0', tokens_used = 0 WHERE session_id='s1';"
  (
    sleep 0.15
    cat >> "$TRANSCRIPT" <<'EOF'
{"type":"assistant","uuid":"u1","message":{"role":"assistant","content":[{"type":"text","text":"done"},{"type":"tool_use","name":"update_goal","input":{"status":"complete"}}],"usage":{"input_tokens":200,"output_tokens":80}}}
EOF
  ) &
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"stop_hook_active\":false}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/stop.sh"
  wait
  [ "$status" -eq 0 ]
  ROW=$(sqlite3 "$DB_PATH" "SELECT status || '|' || tokens_used FROM goals WHERE session_id='s1';")
  [ "$ROW" = "complete|280" ]
  EVENTS=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM goal_events WHERE event_type='final_turn_accounted' AND status_before='complete' AND status_after='complete';")
  [ "$EVENTS" = "1" ]
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

@test "stop hook preserves objective pipes through JSON row parsing" {
  sqlite3 "$DB_PATH" "UPDATE goals SET objective='line one | line two' WHERE session_id='s1';"
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"stop_hook_active\":false}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/stop.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"decision":"block"'* ]]
  echo "$output" | jq -e '.reason | contains("line one | line two")' >/dev/null
}

@test "stop hook exits silently when continuation decrement version race is lost" {
  sqlite3 "$DB_PATH" "
    CREATE TRIGGER bump_goal_version_after_lease
    AFTER INSERT ON continuation_leases
    BEGIN
      UPDATE goals SET version = version + 1 WHERE session_id = NEW.session_id;
    END;
  "
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"stop_hook_active\":false}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/stop.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  REM=$(sqlite3 "$DB_PATH" "SELECT continuations_remaining FROM goals WHERE session_id='s1';")
  [ "$REM" = "50" ]
  EVENTS=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM goal_events WHERE event_type='continuation_injected';")
  [ "$EVENTS" = "0" ]
  LEASES=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM continuation_leases WHERE session_id='s1';")
  [ "$LEASES" = "0" ]
}

@test "stop hook exits silently when evaluator completes after continuation decrement" {
  sqlite3 "$DB_PATH" "
    CREATE TRIGGER complete_goal_after_decrement
    AFTER UPDATE OF continuations_remaining ON goals
    WHEN NEW.continuations_remaining = OLD.continuations_remaining - 1
    BEGIN
      UPDATE goals
        SET status = 'complete',
            resume_at_ms = NULL,
            version = version + 1
        WHERE session_id = NEW.session_id;
    END;
  "
  INPUT="{\"session_id\":\"s1\",\"transcript_path\":\"$TRANSCRIPT\",\"stop_hook_active\":false}"
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/stop.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  ROW=$(sqlite3 "$DB_PATH" "SELECT status || '|' || continuations_remaining FROM goals WHERE session_id='s1';")
  [ "$ROW" = "complete|49" ]
  EVENTS=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM goal_events WHERE event_type='continuation_injected';")
  [ "$EVENTS" = "0" ]
  LEASES=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM continuation_leases WHERE session_id='s1';")
  [ "$LEASES" = "0" ]
}
