#!/usr/bin/env bash
# Token-accounting helpers for claude-goal hooks.
# Requires: $DB_PATH env var. Source sqlite-retry.sh before sourcing this file.

MAX_USAGE_FIELD=9007199254740991

# ms_now: cross-platform millisecond timestamp.
ms_now() {
  local ts
  ts=$(date +%s%3N 2>/dev/null)
  if [[ "$ts" =~ ^[0-9]+$ ]]; then
    echo "$ts"
  else
    python3 -c "import time; print(int(time.time()*1000))"
  fi
}

# read_usage_field LINE FIELD
# Prints a non-negative integer token count, defaulting missing/null fields to 0.
# Prints "__invalid__" for malformed usage so callers can pause as accounting_error
# instead of silently corrupting token accounting.
read_usage_field() {
  local line="$1"
  local field="$2"
  local value
  value=$(printf '%s' "$line" | jq -er --arg field "$field" --argjson max "$MAX_USAGE_FIELD" '
    (.message.usage[$field] // 0) as $v
    | if ($v | type) == "number" then
        if $v >= 0 and $v <= $max and (($v | floor) == $v) then ($v | tostring) else "__invalid__" end
      else "__invalid__"
      end
  ' 2>/dev/null || echo "__invalid__")
  echo "$value"
}

# tokens_from_jsonl_line: prints token sum for one JSONL line, or "" if not an assistant message.
tokens_from_jsonl_line() {
  local line="$1"
  local type
  type=$(printf '%s' "$line" | jq -r '.type // ""')
  [[ "$type" != "assistant" ]] && { echo ""; return 0; }
  local has_usage
  has_usage=$(printf '%s' "$line" | jq 'has("message") and (.message | has("usage"))' 2>/dev/null)
  [[ "$has_usage" != "true" ]] && { echo ""; return 0; }
  local input cache_create output
  input=$(read_usage_field "$line" "input_tokens")
  cache_create=$(read_usage_field "$line" "cache_creation_input_tokens")
  output=$(read_usage_field "$line" "output_tokens")
  [[ "$input" == "__invalid__" || "$cache_create" == "__invalid__" || "$output" == "__invalid__" ]] && { echo ""; return 0; }
  echo $((input + cache_create + output))
}

# last_uuid_before_offset: return the last JSONL uuid before byte offset.
# Single jq pass over the prefix (the old per-line loop spawned one jq
# process per JSONL line, which dominated hook latency on long transcripts).
last_uuid_before_offset() {
  local transcript="$1"
  local end_offset="$2"

  (( end_offset <= 0 )) && { echo ""; return 0; }

  head -c "$end_offset" "$transcript" | jq -Rrn '
    [inputs | fromjson? // empty | if type == "object" then (.uuid // "") | tostring else "" end | select(length > 0)]
    | last // ""
  ' 2>/dev/null || echo ""
}

# sum_transcript: stream JSONL from start_offset, optionally verify previous uuid.
# Outputs: "tokens_delta|last_uuid|end_offset|cursor_reset|cap_field"
#   cursor_reset=1 → caller should re-sum from 0 (transcript was compacted/reset)
#   cap_field non-empty → an invalid usage field was seen; caller should pause goal
sum_transcript() {
  local transcript="$1"
  local start_offset="$2"
  local expected_previous_uuid="$3"

  local tokens_delta=0
  local last_uuid=""
  local end_offset=0
  local cursor_reset=0
  local cap_field=""

  if [[ ! -r "$transcript" ]]; then
    echo "0|||0|"
    return 0
  fi

  end_offset=$(wc -c < "$transcript" | tr -d ' ')

  # File shrank — transcript was reset/compacted. Signal cursor_reset.
  if (( start_offset > end_offset )); then
    echo "0||$end_offset|1|"
    return 0
  fi

  # Verify that the byte cursor still points immediately after the last UUID
  # we accounted. The first record after the cursor is normally new appended
  # data, so comparing that record to the previous UUID would false-positive
  # on every ordinary append.
  if (( start_offset > 0 )) && [[ -n "$expected_previous_uuid" ]]; then
    local previous_uuid
    previous_uuid=$(last_uuid_before_offset "$transcript" "$start_offset")
    if [[ "$previous_uuid" != "$expected_previous_uuid" ]]; then
      echo "0||$end_offset|1|"
      return 0
    fi
  fi

  # At EOF with a valid cursor: nothing new to account.
  if (( start_offset == end_offset )); then
    echo "0||$end_offset|0|"
    return 0
  fi

  # Single jq pass over the appended window: sums usage tokens, tracks the
  # last uuid, and reports the first invalid usage field in line order.
  # Replaces the old per-line loop that spawned ~5 jq processes per JSONL
  # line — the dominant cost of every PostToolBatch/Stop hook invocation.
  local summary
  summary=$(tail -c +$((start_offset + 1)) "$transcript" | jq -Rrn --argjson max "$MAX_USAGE_FIELD" '
    def usage_field($u; $f):
      ($u[$f] // 0) as $v
      | if ($v | type) == "number" and $v >= 0 and $v <= $max and (($v | floor) == $v)
        then {ok: true, value: $v}
        else {ok: false, value: 0}
        end;
    reduce (inputs | fromjson? // empty) as $rec (
      {delta: 0, uuid: "", cap: ""};
      if .cap != "" then .
      else
        (if ($rec | type) == "object" and $rec.type == "assistant"
            and ($rec | has("message")) and (($rec.message | type) == "object")
            and ($rec.message | has("usage")) then
          usage_field($rec.message.usage; "input_tokens") as $i
          | usage_field($rec.message.usage; "cache_creation_input_tokens") as $c
          | usage_field($rec.message.usage; "output_tokens") as $o
          | if ($i.ok | not) then .cap = "input_tokens"
            elif ($c.ok | not) then .cap = "cache_creation_input_tokens"
            elif ($o.ok | not) then .cap = "output_tokens"
            else .delta += ($i.value + $c.value + $o.value)
            end
        else . end)
        | if .cap != "" then .
          elif ($rec | type) == "object" and ((($rec.uuid // "") | tostring) != "") then .uuid = ($rec.uuid | tostring)
          else . end
      end
    )
    | "\(.delta)|\(.uuid)|\(.cap)"
  ' 2>/dev/null)

  IFS='|' read -r tokens_delta last_uuid cap_field <<< "$summary"

  # jq failed outright (missing binary, hard parse crash): report a no-op at
  # the existing cursor so nothing is skipped and a later pass can retry.
  if [[ ! "$tokens_delta" =~ ^[0-9]+$ ]]; then
    echo "0||$start_offset|0|"
    return 0
  fi

  # Invalid usage field: match the legacy contract — zero delta, empty uuid.
  if [[ -n "$cap_field" ]]; then
    echo "0||$end_offset|0|$cap_field"
    return 0
  fi

  echo "$tokens_delta|$last_uuid|$end_offset|$cursor_reset|$cap_field"
}

# pause_as_degraded SESSION_ID
# Flip an active or budget_limited goal into paused with paused_reason='degraded'.
# Used as the catch-all when stop.sh hits an unhandled error.
# Idempotent: if status is already terminal (or already paused), no-op.
pause_as_degraded() {
  local session_id="$1"
  [[ -z "$session_id" ]] && return 0
  local sid_esc
  sid_esc=$(sql_escape "$session_id")
  local now
  now=$(ms_now)
  sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" "
    BEGIN IMMEDIATE;
    UPDATE goals SET status = 'paused', paused_reason = 'degraded',
      time_used_seconds = time_used_seconds + COALESCE(($now - resume_at_ms)/1000, 0),
      resume_at_ms = NULL, version = version + 1, updated_at_ms = $now
      WHERE session_id = '$sid_esc' AND status IN ('active','budget_limited');
    INSERT INTO goal_events (session_id, goal_id, hook_name, event_type, status_after, pid, created_at_ms)
      SELECT '$sid_esc', goal_id, 'stop', 'paused_degraded', 'paused', $$, $now
      FROM goals WHERE session_id = '$sid_esc'
        AND (SELECT changes()) = 1;
    COMMIT;
  " >/dev/null 2>&1
}

# recover_legacy_usage_cap_pause SESSION_ID HOOK_NAME
# v0.2.4 and earlier paused valid large usage fields as cap_exceeded. v0.2.5
# counts those fields normally, so legacy false-positive pauses can recover
# automatically. Future malformed usage uses invalid_usage_field and is not
# auto-resumed by this compatibility path.
recover_legacy_usage_cap_pause() {
  local session_id="$1"
  local hook_name="${2:-accounting-core}"
  [[ -z "$session_id" || ! -f "${DB_PATH:-}" ]] && return 1

  local sid_esc
  sid_esc=$(sql_escape "$session_id")

  local row
  row=$(sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" \
    "SELECT goal_id || '|' || status || '|' || COALESCE(paused_reason,'') || '|' || accounting_uncertain || '|' || version FROM goals WHERE session_id = '$sid_esc';" 2>/dev/null || echo "")
  [[ -z "$row" ]] && return 1

  local goal_id status paused_reason accounting_uncertain version
  IFS='|' read -r goal_id status paused_reason accounting_uncertain version <<< "$row"
  [[ "$status" == "paused" && "$paused_reason" == "accounting_error" && "$accounting_uncertain" == "0" ]] || return 1

  local gid_esc
  gid_esc=$(sql_escape "$goal_id")

  local latest
  latest=$(sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" "
    SELECT event_type || '|' || COALESCE(json_extract(payload_json, '$.cursor_reset'), 0)
    FROM goal_events
    WHERE session_id = '$sid_esc' AND goal_id = '$gid_esc'
    ORDER BY id DESC
    LIMIT 1;
  " 2>/dev/null || echo "")
  [[ -n "$latest" ]] || return 1

  local event_type cursor_reset
  IFS='|' read -r event_type cursor_reset <<< "$latest"
  [[ "$event_type" == "cap_exceeded" && "$cursor_reset" == "0" ]] || return 1

  local now hook_esc result
  now=$(ms_now)
  hook_esc=$(sql_escape "$hook_name")
  result=$(sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" "
    BEGIN IMMEDIATE;
    UPDATE goals SET
      status = 'active',
      paused_reason = NULL,
      resume_at_ms = $now,
      version = version + 1,
      updated_at_ms = $now
    WHERE session_id = '$sid_esc'
      AND goal_id = '$gid_esc'
      AND status = 'paused'
      AND paused_reason = 'accounting_error'
      AND accounting_uncertain = 0
      AND version = $version;
    INSERT INTO goal_events (session_id, goal_id, hook_name, event_type, status_before, status_after, payload_json, pid, created_at_ms)
      SELECT '$sid_esc', '$gid_esc', '$hook_esc', 'legacy_usage_cap_recovered', 'paused', 'active',
        '{\"reason\":\"v0.2.5 removed per-message usage caps\"}', $$, $now
      WHERE EXISTS (
        SELECT 1 FROM goals
        WHERE session_id = '$sid_esc' AND goal_id = '$gid_esc' AND version = $((version + 1))
      );
    SELECT changes();
    COMMIT;
  " 2>/dev/null || echo "0")
  [[ "$result" != "0" ]]
}

# account_advance — DEPRECATED.
# Multiple sql_retry calls open independent connections so BEGIN IMMEDIATE in one
# call doesn't carry to the next. Use account_advance_inline instead.
# Kept for reference; production hooks call account_advance_inline.
account_advance() {
  local session_id="$1"
  local transcript="$2"
  account_advance_inline "$session_id" "$transcript" ""
}

# account_subagent_inline SESSION_ID TRANSCRIPT AGENT_ID
# Accounts a subagent transcript with a per-agent cursor, then rolls the sum
# into goals.subagent_tokens. This keeps the parent transcript cursor isolated.
account_subagent_inline() {
  local session_id="$1"
  local transcript="$2"
  local agent_id="$3"
  local retry_count="${4:-0}"

  [[ -z "$agent_id" ]] && return 0

  local row
  row=$(sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" \
    "SELECT goal_id || '|' || status || '|' || tokens_used || '|' || subagent_tokens || '|' || version || '|' || COALESCE(token_budget,'') FROM goals WHERE session_id = '$(sql_escape "$session_id")';" 2>/dev/null)
  [[ -z "$row" ]] && return 0

  local goal_id current_status tokens_used subagent_tokens version token_budget
  IFS='|' read -r goal_id current_status tokens_used subagent_tokens version token_budget <<< "$row"

  local sid_esc gid_esc aid_esc transcript_esc
  sid_esc=$(sql_escape "$session_id")
  gid_esc=$(sql_escape "$goal_id")
  aid_esc=$(sql_escape "$agent_id")
  transcript_esc=$(sql_escape "$transcript")

  local cursor_row
  cursor_row=$(sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" \
    "SELECT tokens_used || '|' || last_accounted_byte_offset || '|' || COALESCE(last_accounted_uuid, '') FROM subagent_token_cursors WHERE session_id = '$sid_esc' AND goal_id = '$gid_esc' AND agent_id = '$aid_esc';" 2>/dev/null)

  local agent_tokens=0 byte_offset=0 last_uuid=""
  if [[ -n "$cursor_row" ]]; then
    IFS='|' read -r agent_tokens byte_offset last_uuid <<< "$cursor_row"
  fi

  local now
  now=$(ms_now)

  local result
  result=$(sum_transcript "$transcript" "$byte_offset" "$last_uuid")
  local tokens_delta new_last_uuid end_offset cursor_reset cap_field
  IFS='|' read -r tokens_delta new_last_uuid end_offset cursor_reset cap_field <<< "$result"

  if (( cursor_reset == 0 && tokens_delta == 0 && end_offset == byte_offset )); then
    return 0
  fi

  if [[ -n "$cap_field" ]]; then
    local CAP_RESULT
    CAP_RESULT=$(sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" "
      BEGIN IMMEDIATE;
      UPDATE goals SET
        status = 'paused',
        paused_reason = 'accounting_error',
        time_used_seconds = time_used_seconds + COALESCE(($now - resume_at_ms) / 1000, 0),
        resume_at_ms = NULL,
        version = version + 1,
        updated_at_ms = $now
      WHERE session_id = '$sid_esc' AND goal_id = '$gid_esc' AND version = $version
        AND status IN ('active', 'budget_limited');
      INSERT INTO goal_events (session_id, goal_id, hook_name, event_type, status_before, status_after, payload_json, pid, created_at_ms)
        SELECT '$sid_esc', '$gid_esc', 'accounting-core', 'invalid_usage_field', 'active', 'paused',
          '{\"usage_field\":\"$cap_field\",\"agent_id\":\"$aid_esc\"}', $$, $now
        WHERE EXISTS (
          SELECT 1 FROM goals
          WHERE session_id = '$sid_esc' AND goal_id = '$gid_esc' AND version = $((version + 1))
        );
      SELECT changes();
      COMMIT;
    " 2>/dev/null || echo "0")
    if [[ "$CAP_RESULT" = "0" ]]; then
      log_info "post-tool-batch: version_race_lost (subagent invalid_usage) session_id=$session_id agent_id=$agent_id"
    fi
    return 0
  fi

  local accounting_uncertain=0
  local new_agent_tokens=$((agent_tokens + tokens_delta))

  if (( cursor_reset == 1 )); then
    result=$(sum_transcript "$transcript" 0 "")
    IFS='|' read -r tokens_delta new_last_uuid end_offset cursor_reset cap_field <<< "$result"
    if [[ -n "$cap_field" ]]; then
      local RESET_CAP_RESULT
      RESET_CAP_RESULT=$(sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" "
        BEGIN IMMEDIATE;
        UPDATE goals SET
          status = 'paused',
          paused_reason = 'accounting_error',
          time_used_seconds = time_used_seconds + COALESCE(($now - resume_at_ms) / 1000, 0),
          resume_at_ms = NULL,
          version = version + 1,
          updated_at_ms = $now
        WHERE session_id = '$sid_esc' AND goal_id = '$gid_esc' AND version = $version
          AND status IN ('active', 'budget_limited');
        INSERT INTO goal_events (session_id, goal_id, hook_name, event_type, status_before, status_after, payload_json, pid, created_at_ms)
          SELECT '$sid_esc', '$gid_esc', 'accounting-core', 'invalid_usage_field', 'active', 'paused',
            '{\"usage_field\":\"$cap_field\",\"cursor_reset\":1,\"agent_id\":\"$aid_esc\"}', $$, $now
          WHERE EXISTS (
            SELECT 1 FROM goals
            WHERE session_id = '$sid_esc' AND goal_id = '$gid_esc' AND version = $((version + 1))
          );
        SELECT changes();
        COMMIT;
      " 2>/dev/null || echo "0")
      if [[ "$RESET_CAP_RESULT" = "0" ]]; then
        log_info "post-tool-batch: version_race_lost (subagent invalid_usage cursor_reset) session_id=$session_id agent_id=$agent_id"
      fi
      return 0
    fi
    if (( tokens_delta > agent_tokens )); then
      new_agent_tokens=$tokens_delta
    else
      new_agent_tokens=$agent_tokens
    fi
    accounting_uncertain=1
  fi

  local last_uuid_value="NULL"
  [[ -n "$new_last_uuid" ]] && last_uuid_value="'$(sql_escape "$new_last_uuid")'"

  local new_subagent_tokens=$((subagent_tokens - agent_tokens + new_agent_tokens))
  (( new_subagent_tokens < 0 )) && new_subagent_tokens=$new_agent_tokens
  local total_tokens=$((tokens_used + new_subagent_tokens))

  local budget_clause=""
  if [[ "$current_status" != "complete" && "$current_status" != "blocked" && -n "$token_budget" ]] && (( total_tokens >= token_budget )); then
    budget_clause=",
      status = 'budget_limited',
      time_used_seconds = time_used_seconds + COALESCE(($now - resume_at_ms) / 1000, 0),
      resume_at_ms = NULL"
  fi

  local status_guard="'active','budget_limited'"
  if [[ "$current_status" == "complete" ]]; then
    status_guard="'active','budget_limited','complete'"
  elif [[ "$current_status" == "blocked" ]]; then
    status_guard="'active','budget_limited','blocked'"
  fi

  local TX_RESULT
  TX_RESULT=$(sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" "
    BEGIN IMMEDIATE;
    UPDATE goals SET
      subagent_tokens = $new_subagent_tokens,
      accounting_uncertain = CASE WHEN $accounting_uncertain = 1 THEN 1 ELSE accounting_uncertain END,
      version = version + 1,
      updated_at_ms = $now
      $budget_clause
    WHERE session_id = '$sid_esc' AND goal_id = '$gid_esc' AND version = $version
      AND status IN ($status_guard);
    INSERT INTO subagent_token_cursors (
      session_id, goal_id, agent_id, transcript_path, tokens_used,
      last_accounted_byte_offset, last_accounted_uuid, accounting_uncertain,
      updated_at_ms
    )
      SELECT '$sid_esc', '$gid_esc', '$aid_esc', '$transcript_esc', $new_agent_tokens,
        $end_offset, $last_uuid_value, $accounting_uncertain, $now
      WHERE (SELECT changes()) = 1
      ON CONFLICT(session_id, goal_id, agent_id) DO UPDATE SET
        transcript_path = excluded.transcript_path,
        tokens_used = excluded.tokens_used,
        last_accounted_byte_offset = excluded.last_accounted_byte_offset,
        last_accounted_uuid = excluded.last_accounted_uuid,
        accounting_uncertain = excluded.accounting_uncertain,
        updated_at_ms = excluded.updated_at_ms;
    INSERT INTO goal_events (session_id, goal_id, hook_name, event_type, tokens_delta, version_before, version_after, payload_json, pid, created_at_ms)
      SELECT '$sid_esc', '$gid_esc', 'post-tool-batch', 'tokens_accounted', $tokens_delta, $version, $((version + 1)),
        '{\"agent_id\":\"$aid_esc\",\"transcript_path\":\"$transcript_esc\"}', $$, $now
      WHERE EXISTS (
        SELECT 1 FROM goals
        WHERE session_id = '$sid_esc' AND goal_id = '$gid_esc' AND version = $((version + 1))
      );
    SELECT changes();
    COMMIT;
  " 2>/dev/null || echo "0")
  if [[ "$TX_RESULT" = "0" ]]; then
    log_info "post-tool-batch: version_race_lost (subagent) session_id=$session_id agent_id=$agent_id"
    if (( retry_count < 2 )); then
      sleep 0.05
      account_subagent_inline "$session_id" "$transcript" "$agent_id" "$((retry_count + 1))"
    fi
  fi
}

# account_advance_inline — canonical entry point for hooks.
# Opens a single sqlite3 process with BEGIN IMMEDIATE ... COMMIT.
# No nested-transaction risk. Version-guarded; race losers roll back cleanly.
account_advance_inline() {
  local session_id="$1"
  local transcript="$2"
  local agent_id="${3:-}"

  if [[ -n "$agent_id" ]]; then
    account_subagent_inline "$session_id" "$transcript" "$agent_id"
    return $?
  fi

  # Read current state (short auto-commit read; WAL allows concurrent readers).
  local row
  row=$(sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" \
    "SELECT goal_id || '|' || status || '|' || tokens_used || '|' || subagent_tokens || '|' || version || '|' || COALESCE(token_budget,'') || '|' || last_accounted_byte_offset || '|' || COALESCE(last_accounted_uuid, '') FROM goals WHERE session_id = '$(sql_escape "$session_id")';" 2>/dev/null)
  [[ -z "$row" ]] && return 0

  local goal_id current_status tokens_used subagent_tokens version token_budget byte_offset last_uuid
  IFS='|' read -r goal_id current_status tokens_used subagent_tokens version token_budget byte_offset last_uuid <<< "$row"

  local now
  now=$(ms_now)

  # Escaped SQL-safe copies of identifiers.
  local sid_esc gid_esc
  sid_esc=$(sql_escape "$session_id")
  gid_esc=$(sql_escape "$goal_id")

  # APPEND path: stream from last_accounted_byte_offset, verifying first uuid matches.
  local result
  result=$(sum_transcript "$transcript" "$byte_offset" "$last_uuid")
  local tokens_delta new_last_uuid end_offset cursor_reset cap_field
  IFS='|' read -r tokens_delta new_last_uuid end_offset cursor_reset cap_field <<< "$result"

  # Idempotent no-op: cursor is already at EOF and no new token-bearing
  # content was found. Do not bump version, clear UUIDs, or emit events.
  if (( cursor_reset == 0 && tokens_delta == 0 && end_offset == byte_offset )); then
    return 0
  fi

  # Invalid usage on append path — pause the goal as accounting_error.
  # Fix 1: INSERT gated by WHERE EXISTS so it only fires when UPDATE succeeded.
  # Fix 2: status guard added to UPDATE so a concurrent pause isn't overwritten.
  if [[ -n "$cap_field" ]]; then
    local RESULT
    RESULT=$(sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" "
      BEGIN IMMEDIATE;
      UPDATE goals SET
        status = 'paused',
        paused_reason = 'accounting_error',
        time_used_seconds = time_used_seconds + COALESCE(($now - resume_at_ms) / 1000, 0),
        resume_at_ms = NULL,
        version = version + 1,
        updated_at_ms = $now
      WHERE session_id = '$sid_esc' AND goal_id = '$gid_esc' AND version = $version
        AND status IN ('active', 'budget_limited');
      INSERT INTO goal_events (session_id, goal_id, hook_name, event_type, status_before, status_after, payload_json, pid, created_at_ms)
        SELECT '$sid_esc', '$gid_esc', 'accounting-core', 'invalid_usage_field', 'active', 'paused', '{\"usage_field\":\"$cap_field\"}', $$, $now
        WHERE EXISTS (
          SELECT 1 FROM goals
          WHERE session_id = '$sid_esc' AND goal_id = '$gid_esc' AND version = $((version + 1))
        );
      SELECT changes();
      COMMIT;
    " 2>/dev/null || echo "0")
    if [[ "$RESULT" = "0" ]]; then
      log_info "post-tool-batch: version_race_lost (invalid_usage) session_id=$session_id"
    fi
    return 0
  fi

  local accounting_uncertain=0
  local new_tokens_used=$((tokens_used + tokens_delta))

  # CURSOR-RESET path: transcript was compacted or uuid mismatch — re-sum from offset 0.
  if (( cursor_reset == 1 )); then
    result=$(sum_transcript "$transcript" 0 "")
    IFS='|' read -r tokens_delta new_last_uuid end_offset cursor_reset cap_field <<< "$result"
    # Invalid-usage check on full re-sum, gated by WHERE EXISTS.
    # Fix 2: status guard added to UPDATE.
    if [[ -n "$cap_field" ]]; then
      local RESULT
      RESULT=$(sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" "
        BEGIN IMMEDIATE;
        UPDATE goals SET
          status = 'paused',
          paused_reason = 'accounting_error',
          time_used_seconds = time_used_seconds + COALESCE(($now - resume_at_ms) / 1000, 0),
          resume_at_ms = NULL,
          version = version + 1,
          updated_at_ms = $now
        WHERE session_id = '$sid_esc' AND goal_id = '$gid_esc' AND version = $version
          AND status IN ('active', 'budget_limited');
        INSERT INTO goal_events (session_id, goal_id, hook_name, event_type, status_before, status_after, payload_json, pid, created_at_ms)
          SELECT '$sid_esc', '$gid_esc', 'accounting-core', 'invalid_usage_field', 'active', 'paused', '{\"usage_field\":\"$cap_field\",\"cursor_reset\":1}', $$, $now
          WHERE EXISTS (
            SELECT 1 FROM goals
            WHERE session_id = '$sid_esc' AND goal_id = '$gid_esc' AND version = $((version + 1))
          );
        SELECT changes();
        COMMIT;
      " 2>/dev/null || echo "0")
      if [[ "$RESULT" = "0" ]]; then
        log_info "post-tool-batch: version_race_lost (invalid_usage cursor_reset) session_id=$session_id"
      fi
      return 0
    fi
    # MONOTONIC invariant: never decrease tokens_used.
    if (( tokens_delta > tokens_used )); then
      new_tokens_used=$tokens_delta
    else
      new_tokens_used=$tokens_used
    fi
    accounting_uncertain=1
  fi

  # Only write last_accounted_uuid when the transcript window produced one.
  # This keeps no-token/non-UUID windows from clearing the previous cursor.
  local last_uuid_clause=""
  [[ -n "$new_last_uuid" ]] && last_uuid_clause="last_accounted_uuid = '$(sql_escape "$new_last_uuid")',"

  # Atomic budget transition: flip to budget_limited in the same UPDATE.
  local budget_clause=""
  local new_total_tokens=$((new_tokens_used + subagent_tokens))
  if [[ "$current_status" != "complete" && "$current_status" != "blocked" && -n "$token_budget" ]] && (( new_total_tokens >= token_budget )); then
    budget_clause=",
      status = 'budget_limited',
      time_used_seconds = time_used_seconds + COALESCE(($now - resume_at_ms) / 1000, 0),
      resume_at_ms = NULL"
  fi

  local status_guard="'active','budget_limited'"
  if [[ "$current_status" == "complete" ]]; then
    status_guard="'active','budget_limited','complete'"
  elif [[ "$current_status" == "blocked" ]]; then
    status_guard="'active','budget_limited','blocked'"
  fi

  # Single sqlite3 invocation: BEGIN IMMEDIATE ... COMMIT.
  # Fix 1: INSERT uses WHERE EXISTS so it only fires when the UPDATE actually incremented version.
  # Fix 2: status guard closes concurrent pause/abandon windows while still
  # allowing F5 to account final tokens after update_goal has completed the row.
  local TX_RESULT
  TX_RESULT=$(sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" "
    BEGIN IMMEDIATE;
    UPDATE goals SET
      tokens_used = $new_tokens_used,
      last_accounted_byte_offset = $end_offset,
      $last_uuid_clause
      accounting_uncertain = $accounting_uncertain,
      version = version + 1,
      updated_at_ms = $now
      $budget_clause
    WHERE session_id = '$sid_esc' AND goal_id = '$gid_esc' AND version = $version
      AND status IN ($status_guard);
    INSERT INTO goal_events (session_id, goal_id, hook_name, event_type, tokens_delta, version_before, version_after, pid, created_at_ms)
      SELECT '$sid_esc', '$gid_esc', 'post-tool-batch', 'tokens_accounted', $tokens_delta, $version, $((version + 1)), $$, $now
      WHERE EXISTS (
        SELECT 1 FROM goals
        WHERE session_id = '$sid_esc' AND goal_id = '$gid_esc' AND version = $((version + 1))
      );
    SELECT changes();
    COMMIT;
  " 2>/dev/null || echo "0")
  if [[ "$TX_RESULT" = "0" ]]; then
    log_info "post-tool-batch: version_race_lost session_id=$session_id"
  fi
}
