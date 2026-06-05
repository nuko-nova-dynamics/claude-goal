#!/usr/bin/env bash
set -euo pipefail

DB_PATH_ARG="${1:?usage: init-test-db.sh /path/to/goals.db}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

sqlite3 "$DB_PATH_ARG" < "$REPO_ROOT/mcp/goal-server/src/migrations/001_initial.sql"
sqlite3 "$DB_PATH_ARG" < "$REPO_ROOT/mcp/goal-server/src/migrations/002_subagent_tokens.sql"
sqlite3 "$DB_PATH_ARG" < "$REPO_ROOT/mcp/goal-server/src/migrations/003_blocked_status.sql"
sqlite3 "$DB_PATH_ARG" < "$REPO_ROOT/mcp/goal-server/src/migrations/004_budget_profiles.sql"
