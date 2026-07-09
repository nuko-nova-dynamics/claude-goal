#!/usr/bin/env bash
# Source this file after DB_PATH is set. Provides a narrow runtime migration
# guard for hook/CLI paths that may run before the MCP server has started.

SCHEMA_EXPECTED_VERSION=5

schema_migration_dir() {
  local root="${CLAUDE_PLUGIN_ROOT:-}"
  if [[ -z "$root" && -n "${SCRIPT_DIR:-}" ]]; then
    root="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)"
  fi

  local candidate
  for candidate in \
    "$root/mcp/goal-server/dist/migrations" \
    "$root/mcp/goal-server/src/migrations"; do
    if [[ -n "$candidate" && -d "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

ensure_schema_current() {
  [[ -n "${DB_PATH:-}" && -f "$DB_PATH" ]] || return 0
  command -v sqlite3 >/dev/null 2>&1 || return 0

  local current migration_dir migration_file
  current=$(sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" \
    "SELECT version FROM schema_version LIMIT 1;" 2>/dev/null || echo "")

  [[ "$current" =~ ^[0-9]+$ ]] || return 1
  (( current == SCHEMA_EXPECTED_VERSION )) && return 0
  (( current > SCHEMA_EXPECTED_VERSION )) && return 1

  # Runtime shell migration is intentionally narrow: packaged v0.2.6 only
  # needs to lift existing v4 databases before hooks enforce the new envelopes.
  # Full fresh/v1-v5 migrations remain owned by the MCP server migration runner.
  if (( current != 4 )); then
    return 1
  fi

  migration_dir=$(schema_migration_dir) || return 1
  migration_file="$migration_dir/005_larger_goal_envelopes.sql"
  [[ -r "$migration_file" ]] || return 1

  local migration_sql
  migration_sql=$(cat "$migration_file") || return 1
  sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" \
    "BEGIN IMMEDIATE; ${migration_sql}
COMMIT;" || return 1
  current=$(sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" \
    "SELECT version FROM schema_version LIMIT 1;" 2>/dev/null || echo "")
  [[ "$current" = "$SCHEMA_EXPECTED_VERSION" ]]
}
