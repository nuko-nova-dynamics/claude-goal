#!/usr/bin/env bats

setup() {
  TMPDIR_TEST=$(mktemp -d)
  export DB_PATH="$TMPDIR_TEST/g.db"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  "$REPO_ROOT/tests/helpers/init-test-db.sh" "$DB_PATH"
  source "$REPO_ROOT/scripts/lib/sqlite-retry.sh"
  source "$REPO_ROOT/scripts/lib/lease.sh"
}

teardown() { rm -rf "$TMPDIR_TEST"; }

@test "lease_acquire returns 0 when no prior lease" {
  run lease_acquire "s1" "g1" 12345
  [ "$status" -eq 0 ]
}

@test "lease_acquire steals an expired lease" {
  PAST=$(($(date +%s 2>/dev/null) * 1000 - 60000))
  sqlite3 "$DB_PATH" "INSERT INTO continuation_leases VALUES ('s1', 'g1', 9999, 'oldhost', $PAST, $((PAST + 1000)));"
  run lease_acquire "s1" "g1" 12345
  [ "$status" -eq 0 ]
  PID=$(sqlite3 "$DB_PATH" "SELECT owner_pid FROM continuation_leases WHERE session_id='s1';")
  [ "$PID" = "12345" ]
}

@test "lease_acquire returns 1 when fresh lease held by other" {
  FUTURE=$(($(date +%s 2>/dev/null) * 1000 + 60000))
  NOW=$(($(date +%s 2>/dev/null) * 1000))
  sqlite3 "$DB_PATH" "INSERT INTO continuation_leases VALUES ('s1', 'g1', 9999, 'oldhost', $NOW, $FUTURE);"
  run lease_acquire "s1" "g1" 12345
  [ "$status" -eq 1 ]
}

@test "lease_release deletes only matching owner_pid" {
  NOW=$(($(date +%s 2>/dev/null) * 1000))
  FUTURE=$((NOW + 60000))
  sqlite3 "$DB_PATH" "INSERT INTO continuation_leases VALUES ('s1', 'g1', 12345, 'host', $NOW, $FUTURE);"
  lease_release "s1" 99999  # wrong pid — should NOT delete
  COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM continuation_leases WHERE session_id='s1';")
  [ "$COUNT" = "1" ]
  lease_release "s1" 12345  # right pid — should delete
  COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM continuation_leases WHERE session_id='s1';")
  [ "$COUNT" = "0" ]
}
