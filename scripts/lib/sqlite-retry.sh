#!/usr/bin/env bash
# Source this file. Provides: sql_retry "STATEMENT", sql_escape "STRING".
# Requires: $DB_PATH.

# sql_escape: escape single quotes for safe interpolation into SQL string literals.
# Always use as: sql_retry "INSERT INTO t VALUES ('$(sql_escape "$VALUE")')"
sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

sql_retry() {
  local sql="$1"
  local attempt=1
  local max_attempts=5
  local backoff_base_ms=100
  local out
  while (( attempt <= max_attempts )); do
    if out=$(sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" "$sql" 2>&1); then
      printf '%s' "$out"
      return 0
    fi
    case "$out" in
      *"database is locked"*|*"SQLITE_BUSY"*|*"SQLITE_LOCKED"*)
        local jitter=$(( RANDOM % backoff_base_ms ))
        local sleep_ms=$(( backoff_base_ms * attempt + jitter ))
        sleep "$(awk "BEGIN { print $sleep_ms / 1000 }")"
        ;;
      *)
        echo "sql_retry hard error: $out" >&2
        return 1
        ;;
    esac
    (( attempt++ ))
  done
  echo "sql_retry exhausted after $max_attempts attempts: $sql" >&2
  return 1
}
