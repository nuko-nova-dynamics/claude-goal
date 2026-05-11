#!/usr/bin/env bash
# Continuation lease helpers. Requires: $DB_PATH, sqlite-retry.sh sourced.

# lease_acquire SESSION_ID GOAL_ID PID
# Returns 0 if acquired (or stolen-stale), 1 if not.
lease_acquire() {
  local session_id="$1"
  local goal_id="$2"
  local pid="$3"
  local host="${HOSTNAME:-$(hostname)}"
  local now
  # ms_now compatibility: use date +%s%3N on Linux, python3 fallback on macOS
  if date +%s%3N 2>/dev/null | grep -q '^[0-9]\+$'; then
    now=$(date +%s%3N)
  else
    now=$(python3 -c "import time; print(int(time.time()*1000))")
  fi
  local expires=$((now + 300000))  # 5 min

  local sid_esc gid_esc host_esc
  sid_esc=$(sql_escape "$session_id")
  gid_esc=$(sql_escape "$goal_id")
  host_esc=$(sql_escape "$host")

  sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" "
    INSERT INTO continuation_leases
      (session_id, goal_id, owner_pid, owner_host, acquired_at_ms, expires_at_ms)
    VALUES
      ('$sid_esc', '$gid_esc', $pid, '$host_esc', $now, $expires)
    ON CONFLICT(session_id) DO UPDATE SET
      goal_id = excluded.goal_id,
      owner_pid = excluded.owner_pid,
      owner_host = excluded.owner_host,
      acquired_at_ms = excluded.acquired_at_ms,
      expires_at_ms = excluded.expires_at_ms
    WHERE continuation_leases.expires_at_ms < $now;
  " >/dev/null 2>&1 || return 1

  local actual_pid
  actual_pid=$(sqlite3 -bail "$DB_PATH" "SELECT owner_pid FROM continuation_leases WHERE session_id = '$sid_esc';")
  [[ "$actual_pid" = "$pid" ]] && return 0
  return 1
}

# lease_release SESSION_ID PID
# Deletes the lease only if owner_pid matches, so a stale call can't free a fresh lease.
lease_release() {
  local session_id="$1"
  local pid="$2"
  local sid_esc
  sid_esc=$(sql_escape "$session_id")
  sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" \
    "DELETE FROM continuation_leases WHERE session_id = '$sid_esc' AND owner_pid = $pid;" >/dev/null 2>&1
}
