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

# sum_transcript: stream JSONL from start_offset, optionally verify first uuid.
# Outputs: "tokens_delta|last_uuid|end_offset|cursor_reset|cap_field"
#   cursor_reset=1 → caller should re-sum from 0 (transcript was compacted/reset)
#   cap_field non-empty → a per-field cap was exceeded; caller should pause goal
sum_transcript() {
  local transcript="$1"
  local start_offset="$2"
  local expected_first_uuid="$3"

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

  # If we're at or past EOF, check if this is a cursor-reset (file shrank) or genuinely empty.
  if (( start_offset >= end_offset )); then
    if (( start_offset > 0 )) && [[ -n "$expected_first_uuid" ]]; then
      # File shrank — transcript was reset/compacted. Signal cursor_reset.
      echo "0||$end_offset|1|"
    else
      echo "0||$end_offset|0|"
    fi
    return 0
  fi

  local checked_first=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # UUID-based cursor-reset detection: first line's uuid must match expected.
    if (( checked_first == 0 )) && [[ -n "$expected_first_uuid" ]]; then
      local first_line_uuid
      first_line_uuid=$(printf '%s' "$line" | jq -r '.uuid // ""')
      if [[ -n "$first_line_uuid" && "$first_line_uuid" != "$expected_first_uuid" ]]; then
        echo "0||$end_offset|1|"
        return 0
      fi
    fi
    checked_first=1

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

  # APPEND path: stream from last_accounted_byte_offset, verifying first uuid matches.
  local result
  result=$(sum_transcript "$transcript" "$byte_offset" "$last_uuid")
  local tokens_delta new_last_uuid end_offset cursor_reset cap_field
  IFS='|' read -r tokens_delta new_last_uuid end_offset cursor_reset cap_field <<< "$result"

  # Cap exceeded — pause the goal as accounting_error.
  if [[ -n "$cap_field" ]]; then
    sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" "
      BEGIN IMMEDIATE;
      UPDATE goals SET
        status = 'paused',
        paused_reason = 'accounting_error',
        time_used_seconds = time_used_seconds + COALESCE(($now - resume_at_ms) / 1000, 0),
        resume_at_ms = NULL,
        version = version + 1,
        updated_at_ms = $now
      WHERE session_id = '$(sql_escape "$session_id")' AND version = $version;
      INSERT INTO goal_events (session_id, goal_id, hook_name, event_type, status_before, status_after, payload_json, pid, created_at_ms)
        VALUES ('$(sql_escape "$session_id")', '$(sql_escape "$goal_id")', 'accounting-core', 'cap_exceeded', 'active', 'paused', '{\"cap_field\":\"$cap_field\"}', $$, $now);
      COMMIT;
    " 2>/dev/null || true
    return 0
  fi

  local accounting_uncertain=0
  local new_tokens_used=$((tokens_used + tokens_delta))

  # CURSOR-RESET path: transcript was compacted or uuid mismatch — re-sum from offset 0.
  if (( cursor_reset == 1 )); then
    result=$(sum_transcript "$transcript" 0 "")
    IFS='|' read -r tokens_delta new_last_uuid end_offset cursor_reset cap_field <<< "$result"
    # Cap check on full re-sum.
    if [[ -n "$cap_field" ]]; then
      sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" "
        BEGIN IMMEDIATE;
        UPDATE goals SET
          status = 'paused',
          paused_reason = 'accounting_error',
          time_used_seconds = time_used_seconds + COALESCE(($now - resume_at_ms) / 1000, 0),
          resume_at_ms = NULL,
          version = version + 1,
          updated_at_ms = $now
        WHERE session_id = '$(sql_escape "$session_id")' AND version = $version;
        COMMIT;
      " 2>/dev/null || true
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
  sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" "
    BEGIN IMMEDIATE;
    UPDATE goals SET
      tokens_used = $new_tokens_used,
      last_accounted_byte_offset = $end_offset,
      last_accounted_uuid = $new_uuid_sql,
      accounting_uncertain = $accounting_uncertain,
      version = version + 1,
      updated_at_ms = $now
      $budget_clause
    WHERE session_id = '$(sql_escape "$session_id")' AND goal_id = '$(sql_escape "$goal_id")' AND version = $version;
    INSERT INTO goal_events (session_id, goal_id, hook_name, event_type, tokens_delta, version_before, version_after, pid, created_at_ms)
      VALUES ('$(sql_escape "$session_id")', '$(sql_escape "$goal_id")', 'accounting-core', 'tokens_accounted', $tokens_delta, $version, $((version + 1)), $$, $now);
    COMMIT;
  " 2>/dev/null || true
}
