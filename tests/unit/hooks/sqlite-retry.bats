#!/usr/bin/env bats

setup() {
  TMPDIR_TEST=$(mktemp -d)
  export DB_PATH="$TMPDIR_TEST/test.db"
  sqlite3 "$DB_PATH" "CREATE TABLE t (k TEXT PRIMARY KEY, v INTEGER);"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  source "$REPO_ROOT/scripts/lib/sqlite-retry.sh"
}

teardown() {
  rm -rf "$TMPDIR_TEST"
}

@test "sql_retry returns rows on plain SELECT" {
  sqlite3 "$DB_PATH" "INSERT INTO t VALUES ('a', 1);"
  run sql_retry "SELECT v FROM t WHERE k='a';"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "sql_retry succeeds on plain INSERT" {
  run sql_retry "INSERT INTO t VALUES ('b', 2);"
  [ "$status" -eq 0 ]
}

@test "sql_retry exits 1 on hard error (syntax)" {
  run sql_retry "NOT VALID SQL;"
  [ "$status" -eq 1 ]
}

@test "sql_escape doubles single quotes" {
  result=$(sql_escape "O'Brien said \"hi'")
  [ "$result" = "O''Brien said \"hi''" ]
}

@test "sql_escape passes plain strings unchanged" {
  result=$(sql_escape "no quotes here")
  [ "$result" = "no quotes here" ]
}

@test "sql_escape with empty string" {
  result=$(sql_escape "")
  [ -z "$result" ]
}
