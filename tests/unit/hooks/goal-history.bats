#!/usr/bin/env bats

# The goals table has session_id PRIMARY KEY — at most one row per session.
# History is naturally cross-session: each session represents one Claude
# conversation, each with at most one tracked goal.

setup() {
  TMPDIR_TEST=$(mktemp -d)
  export CLAUDE_PLUGIN_DATA="$TMPDIR_TEST"
  export DB_PATH="$TMPDIR_TEST/goals.db"
  export CLAUDE_SESSION_ID="s-current"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export REPO_ROOT
  CLI="$REPO_ROOT/scripts/goal-cli.sh"
  export CLI
  [[ -f "$REPO_ROOT/.runtime-data-dir" ]] && cp "$REPO_ROOT/.runtime-data-dir" "$REPO_ROOT/.runtime-data-dir.bak"
  printf '%s' "$TMPDIR_TEST" > "$REPO_ROOT/.runtime-data-dir"
  "$REPO_ROOT/tests/helpers/init-test-db.sh" "$DB_PATH"
  NOW=$(python3 -c "import time; print(int(time.time()*1000))")
  T_OLD=$((NOW - 30000))
  T_MID=$((NOW - 20000))
  T_NEW=$((NOW - 10000))
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, paused_reason, tokens_used, subagent_tokens, token_budget, budget_source, continuations_remaining, time_used_seconds, created_at_ms, updated_at_ms)
    VALUES ('s-old', 'g-old', 'oldest goal', 'complete', NULL, 5000, 700, 10000, 'tokens', 47, 12, $T_OLD, $T_OLD);"
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, paused_reason, tokens_used, subagent_tokens, token_budget, budget_source, continuations_remaining, time_used_seconds, created_at_ms, updated_at_ms)
    VALUES ('s-mid', 'g-mid', 'middle goal', 'abandoned', 'user', 2000, 0, NULL, 'none', 49, 5, $T_MID, $T_MID);"
  sqlite3 "$DB_PATH" "INSERT INTO goals (session_id, goal_id, objective, status, paused_reason, tokens_used, subagent_tokens, token_budget, budget_profile, budget_source, continuations_remaining, time_used_seconds, created_at_ms, updated_at_ms)
    VALUES ('s-current', 'g-current', 'current session goal', 'active', NULL, 1000, 300, 2000000, 'standard', 'profile', 75, 3, $T_NEW, $T_NEW);"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
  if [[ -f "$REPO_ROOT/.runtime-data-dir.bak" ]]; then
    mv "$REPO_ROOT/.runtime-data-dir.bak" "$REPO_ROOT/.runtime-data-dir"
  else
    rm -f "$REPO_ROOT/.runtime-data-dir"
  fi
}

@test "history (default) shows only current session's goal" {
  run "$CLI" history
  [ "$status" -eq 0 ]
  [[ "$output" == *"current session goal"* ]]
  [[ "$output" != *"oldest goal"* ]]
  [[ "$output" != *"middle goal"* ]]
}

@test "history --all includes every session in descending created order" {
  run "$CLI" history --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"current session goal"* ]]
  [[ "$output" == *"oldest goal"* ]]
  [[ "$output" == *"middle goal"* ]]
  # Descending order: newest first
  CUR_POS=$(echo "$output" | grep -n "current session goal" | head -1 | cut -d: -f1)
  MID_POS=$(echo "$output" | grep -n "middle goal" | head -1 | cut -d: -f1)
  OLD_POS=$(echo "$output" | grep -n "oldest goal" | head -1 | cut -d: -f1)
  [ "$CUR_POS" -lt "$MID_POS" ]
  [ "$MID_POS" -lt "$OLD_POS" ]
}

@test "history --all --format=json returns valid JSON array of all goals" {
  run "$CLI" history --all --format=json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'type == "array" and length == 3' >/dev/null
  echo "$output" | jq -e '.[0].objective == "current session goal"' >/dev/null
  echo "$output" | jq -e '.[0].subagent_tokens == 300' >/dev/null
  echo "$output" | jq -e '.[0].budget_profile == "standard" and .[0].budget_source == "profile"' >/dev/null
}

@test "history with no goals in this session prints a hint" {
  sqlite3 "$DB_PATH" "DELETE FROM goals WHERE session_id='s-current';"
  run "$CLI" history
  [ "$status" -eq 0 ]
  [[ "$output" == *"no goals for this session"* ]]
  [[ "$output" == *"--all"* ]]
}

@test "history shows status, paused_reason, and tokens in human format" {
  run "$CLI" history --all
  [ "$status" -eq 0 ]
  [[ "$output" == *"[active]"* ]]
  [[ "$output" == *"[complete]"* ]]
  [[ "$output" == *"[abandoned (user)]"* ]]
  [[ "$output" == *"tokens=5000/10000"* ]]
  [[ "$output" == *"subagent_tokens=700"* ]]
  [[ "$output" == *"budget=standard profile"* ]]
  [[ "$output" == *"budget=raw tokens"* ]]
  [[ "$output" == *"tokens=2000"* ]]
}
