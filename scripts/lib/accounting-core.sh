#!/usr/bin/env bash
# Token-accounting helpers for claude-goal hooks.
# Requires: $DB_PATH env var. Source sqlite-retry.sh before sourcing this file.

CAP_INPUT=200000
CAP_OUTPUT=100000
CAP_CACHE_CREATE=200000

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
  input=$(printf '%s' "$line" | jq -r '.message.usage.input_tokens // 0')
  cache_create=$(printf '%s' "$line" | jq -r '.message.usage.cache_creation_input_tokens // 0')
  output=$(printf '%s' "$line" | jq -r '.message.usage.output_tokens // 0')
  echo $((input + cache_create + output))
}

# last_uuid_before_offset: return the last JSONL uuid before byte offset.
last_uuid_before_offset() {
  local transcript="$1"
  local end_offset="$2"
  local last_uuid=""

  (( end_offset <= 0 )) && { echo ""; return 0; }

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    local u
    u=$(printf '%s' "$line" | jq -r '.uuid // ""' 2>/dev/null || echo "")
    [[ -n "$u" ]] && last_uuid="$u"
  done < <(head -c "$end_offset" "$transcript")

  echo "$last_uuid"
}

# sum_transcript: stream JSONL from start_offset, optionally verify previous uuid.
# Outputs: "tokens_delta|last_uuid|end_offset|cursor_reset|cap_field"
#   cursor_reset=1 → caller should re-sum from 0 (transcript was compacted/reset)
#   cap_field non-empty → a per-field cap was exceeded; caller should pause goal
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

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue

    # Per-field cap check for assistant messages.
    local type
    type=$(printf '%s' "$line" | jq -r '.type // ""')
    if [[ "$type" == "assistant" ]]; then
      local has_usage
      has_usage=$(printf '%s' "$line" | jq 'has("message") and (.message | has("usage"))' 2>/dev/null)
      if [[ "$has_usage" == "true" ]]; then
        local input cache_create output
        input=$(printf '%s' "$line" | jq -r '.message.usage.input_tokens // 0')
        cache_create=$(printf '%s' "$line" | jq -r '.message.usage.cache_creation_input_tokens // 0')
        output=$(printf '%s' "$line" | jq -r '.message.usage.output_tokens // 0')

        if (( input > CAP_INPUT )); then
          echo "0||$end_offset|0|input_tokens"
          return 0
        fi
        if (( output > CAP_OUTPUT )); then
          echo "0||$end_offset|0|output_tokens"
          return 0
        fi
        if (( cache_create > CAP_CACHE_CREATE )); then
          echo "0||$end_offset|0|cache_creation_input_tokens"
          return 0
        fi
        tokens_delta=$((tokens_delta + input + cache_create + output))
      fi
    fi

    local u
    u=$(printf '%s' "$line" | jq -r '.uuid // ""')
    [[ -n "$u" ]] && last_uuid="$u"

  done < <(tail -c +$((start_offset + 1)) "$transcript")

  echo "$tokens_delta|$last_uuid|$end_offset|$cursor_reset|$cap_field"
}

# account_advance — DEPRECATED.
# Multiple sql_retry calls open independent connections so BEGIN IMMEDIATE in one
# call doesn't carry to the next. Use account_advance_inline instead.
# Kept for reference; production hooks call account_advance_inline.
account_advance() {
  local session_id="$1"
  local transcript="$2"
  account_advance_inline "$session_id" "$transcript"
}

# account_advance_inline — canonical entry point for hooks.
# Opens a single sqlite3 process with BEGIN IMMEDIATE ... COMMIT.
# No nested-transaction risk. Version-guarded; race losers roll back cleanly.
account_advance_inline() {
  local session_id="$1"
  local transcript="$2"

  # Read current state (short auto-commit read; WAL allows concurrent readers).
  local row
  row=$(sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" \
    "SELECT goal_id || '|' || tokens_used || '|' || version || '|' || COALESCE(token_budget,'') || '|' || last_accounted_byte_offset || '|' || COALESCE(last_accounted_uuid, '') FROM goals WHERE session_id = '$(sql_escape "$session_id")';" 2>/dev/null)
  [[ -z "$row" ]] && return 0

  local goal_id tokens_used version token_budget byte_offset last_uuid
  IFS='|' read -r goal_id tokens_used version token_budget byte_offset last_uuid <<< "$row"

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

  # Cap exceeded on append path — pause the goal as accounting_error.
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
        SELECT '$sid_esc', '$gid_esc', 'accounting-core', 'cap_exceeded', 'active', 'paused', '{\"cap_field\":\"$cap_field\"}', $$, $now
        WHERE EXISTS (
          SELECT 1 FROM goals
          WHERE session_id = '$sid_esc' AND goal_id = '$gid_esc' AND version = $((version + 1))
        );
      SELECT changes();
      COMMIT;
    " 2>/dev/null || echo "0")
    if [[ "$RESULT" = "0" ]]; then
      log_info "post-tool-batch: version_race_lost (cap_exceeded) session_id=$session_id"
    fi
    return 0
  fi

  local accounting_uncertain=0
  local new_tokens_used=$((tokens_used + tokens_delta))

  # CURSOR-RESET path: transcript was compacted or uuid mismatch — re-sum from offset 0.
  if (( cursor_reset == 1 )); then
    result=$(sum_transcript "$transcript" 0 "")
    IFS='|' read -r tokens_delta new_last_uuid end_offset cursor_reset cap_field <<< "$result"
    # Cap check on full re-sum.
    # Fix 4: now also inserts paused_accounting_error event, gated by WHERE EXISTS.
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
          SELECT '$sid_esc', '$gid_esc', 'accounting-core', 'paused_accounting_error', 'active', 'paused', '{\"cap_field\":\"$cap_field\",\"cursor_reset\":1}', $$, $now
          WHERE EXISTS (
            SELECT 1 FROM goals
            WHERE session_id = '$sid_esc' AND goal_id = '$gid_esc' AND version = $((version + 1))
          );
        SELECT changes();
        COMMIT;
      " 2>/dev/null || echo "0")
      if [[ "$RESULT" = "0" ]]; then
        log_info "post-tool-batch: version_race_lost (cap_exceeded cursor_reset) session_id=$session_id"
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

  # Determine last_accounted_uuid SQL expression.
  local new_uuid_sql="NULL"
  [[ -n "$new_last_uuid" ]] && new_uuid_sql="'$(sql_escape "$new_last_uuid")'"

  # Atomic budget transition: flip to budget_limited in the same UPDATE.
  local budget_clause=""
  if [[ -n "$token_budget" ]] && (( new_tokens_used >= token_budget )); then
    budget_clause=",
      status = 'budget_limited',
      time_used_seconds = time_used_seconds + COALESCE(($now - resume_at_ms) / 1000, 0),
      resume_at_ms = NULL"
  fi

  # Single sqlite3 invocation: BEGIN IMMEDIATE ... COMMIT.
  # Fix 1: INSERT uses WHERE EXISTS so it only fires when the UPDATE actually incremented version.
  # Fix 2: status IN ('active', 'budget_limited') closes the concurrent-pause window.
  local TX_RESULT
  TX_RESULT=$(sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" "
    BEGIN IMMEDIATE;
    UPDATE goals SET
      tokens_used = $new_tokens_used,
      last_accounted_byte_offset = $end_offset,
      last_accounted_uuid = $new_uuid_sql,
      accounting_uncertain = $accounting_uncertain,
      version = version + 1,
      updated_at_ms = $now
      $budget_clause
    WHERE session_id = '$sid_esc' AND goal_id = '$gid_esc' AND version = $version
      AND status IN ('active', 'budget_limited');
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
