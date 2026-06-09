#!/usr/bin/env bats

setup() {
  TMPDIR_TEST=$(mktemp -d)
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export REPO_ROOT
  export DB_PATH="$TMPDIR_TEST/goals.db"
  export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"

  sqlite3 "$DB_PATH" < "$REPO_ROOT/mcp/goal-server/src/migrations/001_initial.sql"
  sqlite3 "$DB_PATH" < "$REPO_ROOT/mcp/goal-server/src/migrations/002_subagent_tokens.sql"
  sqlite3 "$DB_PATH" < "$REPO_ROOT/mcp/goal-server/src/migrations/003_blocked_status.sql"
  sqlite3 "$DB_PATH" < "$REPO_ROOT/mcp/goal-server/src/migrations/004_budget_profiles.sql"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

@test "ensure_schema_current migrates v4 database to v5" {
  sqlite3 "$DB_PATH" "
    INSERT INTO goals (
      session_id, goal_id, objective, status, token_budget, budget_profile,
      budget_source, continuations_remaining, max_wall_clock_seconds,
      created_at_ms, updated_at_ms
    ) VALUES (
      's1', 'g1', 'x', 'active', 5000000, 'deep',
      'profile', 140, 28800, 1, 1
    );
  "

  run bash -c "source '$REPO_ROOT/scripts/lib/schema.sh'; ensure_schema_current"

  [ "$status" -eq 0 ]
  ROW=$(sqlite3 "$DB_PATH" "SELECT (SELECT version FROM schema_version) || '|' || token_budget || '|' || continuations_remaining || '|' || max_wall_clock_seconds FROM goals WHERE session_id='s1';")
  [ "$ROW" = "5|100000000|1000|86400" ]
}

@test "ensure_schema_current fails without applying stale behavior when v5 migration is missing" {
  FAKE_ROOT="$TMPDIR_TEST/fake-plugin"
  mkdir -p "$FAKE_ROOT/mcp/goal-server/dist/migrations"
  export CLAUDE_PLUGIN_ROOT="$FAKE_ROOT"

  run bash -c "source '$REPO_ROOT/scripts/lib/schema.sh'; ensure_schema_current"

  [ "$status" -ne 0 ]
  VERSION=$(sqlite3 "$DB_PATH" "SELECT version FROM schema_version;")
  [ "$VERSION" = "4" ]
}
