#!/usr/bin/env bash
# Usage: goal-cli.sh <subcommand> [args...]
# Subcommands: status, pause, resume, abandon, extend, reconcile, doctor
# Reads CLAUDE_SESSION_ID from environment if available; else from --session-id flag.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/sqlite-retry.sh"
source "$SCRIPT_DIR/lib/schema.sh"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [[ -z "$PLUGIN_ROOT" ]]; then
  PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

# Resolve plugin data dir via:
#   1. Runtime marker written by session-start.sh on session boot
#   2. Explicit DB_PATH (test/local override when no marker exists)
#   3. CLAUDE_PLUGIN_DATA env (fallback; can leak across plugin contexts)
#   4. Hardcoded fallback (last resort; likely wrong, but better than crashing)
if [[ -n "$PLUGIN_ROOT" && -f "$PLUGIN_ROOT/.runtime-data-dir" ]]; then
  PLUGIN_DATA=$(cat "$PLUGIN_ROOT/.runtime-data-dir")
  DB_PATH="$PLUGIN_DATA/goals.db"
elif [[ -z "${DB_PATH:-}" ]]; then
  if [[ -n "${CLAUDE_PLUGIN_DATA:-}" ]]; then
    PLUGIN_DATA="$CLAUDE_PLUGIN_DATA"
  else
    PLUGIN_DATA="$HOME/.claude/plugins/data/claude-goal"
  fi
  DB_PATH="$PLUGIN_DATA/goals.db"
fi
SESSION_ID="${CLAUDE_SESSION_ID:-}"
FORMAT="text"
ADD_CONT=""
ADD_HOURS=""
ADD_TOKENS=""
ACCEPT_RESET=0
CLEANUP_ACTION=""
CLEANUP_HOURS=""
CLEANUP_HOURS_EXPLICIT=0

SUBCMD="${1:-}"; shift || true

while (( $# > 0 )); do
  case "$1" in
    --session-id=*) SESSION_ID="${1#*=}"; shift ;;
    --session-id) SESSION_ID="$2"; shift 2 ;;
    --format=*) FORMAT="${1#*=}"; shift ;;
    --format) FORMAT="$2"; shift 2 ;;
    --add-continuations=*) ADD_CONT="${1#*=}"; shift ;;
    --add-continuations) ADD_CONT="$2"; shift 2 ;;
    --add-hours=*) ADD_HOURS="${1#*=}"; shift ;;
    --add-hours) ADD_HOURS="$2"; shift 2 ;;
    --add-tokens=*) ADD_TOKENS="${1#*=}"; shift ;;
    --add-tokens) ADD_TOKENS="$2"; shift 2 ;;
    --accept-reset) ACCEPT_RESET=1; shift ;;
    --list) CLEANUP_ACTION="list"; shift ;;
    --delete) CLEANUP_ACTION="delete"; shift ;;
    --older-than) CLEANUP_HOURS="$2"; CLEANUP_HOURS_EXPLICIT=1; shift 2 ;;
    --older-than=*) CLEANUP_HOURS="${1#*=}"; CLEANUP_HOURS_EXPLICIT=1; shift ;;
    --all) HISTORY_ALL=1; shift ;;
    *) shift ;;
  esac
done

# Different default thresholds for --list (show everything) and --delete (be conservative).
if [[ "$CLEANUP_HOURS_EXPLICIT" = "0" ]]; then
  if [[ "$CLEANUP_ACTION" = "list" ]]; then
    CLEANUP_HOURS=0
  else
    CLEANUP_HOURS=24
  fi
fi

# Resolver order: --session-id flag → CLAUDE_SESSION_ID env → marker file → error
if [[ -z "$SESSION_ID" && -n "$PLUGIN_ROOT" && -f "$PLUGIN_ROOT/.runtime-session-id" ]]; then
  SESSION_ID=$(cat "$PLUGIN_ROOT/.runtime-session-id")
fi

# doctor and cleanup don't need session_id; check per-subcommand
case "$SUBCMD" in
  doctor|cleanup) ;;
  *)
    if [[ -z "$SESSION_ID" ]]; then
      echo "error: session id not available; pass --session-id" >&2
      exit 1
    fi
    ;;
esac

SESSION_ID_ESC=$(sql_escape "${SESSION_ID:-}")

sql() { sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" "$@"; }
# macOS-compatible millisecond timestamp
ms_now() { python3 -c "import time; print(int(time.time()*1000))"; }
is_positive_int() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
sql_change_count() {
  printf '%s\n' "$1" | awk '/^[[:space:]]*[0-9]+[[:space:]]*$/ { value=$1 } END { if (value != "") print value; else print "0" }'
}

SCHEMA_READY=1
if [[ -f "$DB_PATH" ]]; then
  if ! ensure_schema_current; then
    SCHEMA_READY=0
    log_error "goal-cli: schema migration guard failed for $DB_PATH"
  fi
fi

case "$SUBCMD" in
  doctor) ;;
  *)
    if [[ "$SCHEMA_READY" = "0" ]]; then
      echo "error: goal database schema migration failed; run /goal-doctor and reload/update the plugin" >&2
      exit 4
    fi
    ;;
esac

case "$SUBCMD" in
  status)
    ROW=$(sql -json "SELECT * FROM goals WHERE session_id = '$SESSION_ID_ESC';")
    if [[ -z "$ROW" || "$ROW" == "[]" ]]; then
      [[ "$FORMAT" == "json" ]] && echo '{"goal":null}' || echo "no goal for this session"
      exit 2
    fi
    # Compute remaining_tokens and convert accounting_uncertain to bool per spec Appendix A.1
    ENRICHED=$(echo "$ROW" | jq '.[0]
      | .subagent_tokens = (.subagent_tokens // 0)
      | .total_tokens_used = (.tokens_used + .subagent_tokens)
      | .remaining_tokens = (if .token_budget then ((.token_budget - .total_tokens_used) | if . < 0 then 0 else . end) else null end)
      | .accounting_uncertain = (.accounting_uncertain == 1)')
    if [[ "$FORMAT" == "json" ]]; then
      echo "$ENRICHED"
    else
      echo "$ENRICHED" | jq -r '
        def budget_label:
          if .budget_source == "auto" then "\(.budget_profile) profile (auto)"
          elif .budget_source == "profile" then "\(.budget_profile) profile"
          elif .budget_source == "tokens" then "raw tokens"
          else "unbounded"
          end;
        "Goal: \(.objective)\nStatus: \(.status)\(if .paused_reason then " (\(.paused_reason))" else "" end)\nBudget: \(budget_label)\nTokens: \(.tokens_used)\(if .token_budget then " / \(.token_budget) (\(.remaining_tokens) remaining)" else "" end)\nSubagent tokens: \(.subagent_tokens)\nTime: \(.time_used_seconds)s\nContinuations remaining: \(.continuations_remaining)\(if .accounting_uncertain then "\nWARNING: accounting uncertain — see /goal-reconcile" else "" end)"'
    fi
    ;;
  pause)
    ROW=$(sql -json "SELECT goal_id, status FROM goals WHERE session_id = '$SESSION_ID_ESC' AND status IN ('active','budget_limited');")
    [[ -z "$ROW" || "$ROW" == "[]" ]] && { echo "no active goal to pause"; exit 2; }
    GOAL_ID=$(echo "$ROW" | jq -r '.[0].goal_id')
    STATUS_BEFORE=$(echo "$ROW" | jq -r '.[0].status')
    GOAL_ID_ESC=$(sql_escape "$GOAL_ID")
    STATUS_BEFORE_ESC=$(sql_escape "$STATUS_BEFORE")
    NOW=$(ms_now)
    sql "BEGIN IMMEDIATE;
         UPDATE goals SET status='paused', paused_reason='user',
           time_used_seconds = time_used_seconds + COALESCE((${NOW} - resume_at_ms)/1000, 0),
           resume_at_ms = NULL, version = version + 1, updated_at_ms = ${NOW}
         WHERE session_id = '$SESSION_ID_ESC' AND goal_id = '$GOAL_ID_ESC';
         INSERT INTO goal_events (session_id, goal_id, hook_name, event_type, status_before, status_after, payload_json, pid, created_at_ms)
         VALUES ('$SESSION_ID_ESC','$GOAL_ID_ESC','goal-cli','goal_paused','$STATUS_BEFORE_ESC','paused','{\"reason\":\"user\"}',$$,${NOW});
         COMMIT;"
    echo "goal paused"
    ;;
  resume)
    ROW=$(sql -json "SELECT goal_id, status, paused_reason FROM goals WHERE session_id = '$SESSION_ID_ESC' AND status IN ('paused','blocked');")
    [[ -z "$ROW" || "$ROW" == "[]" ]] && { echo "no paused or blocked goal to resume"; exit 2; }
    STATUS_BEFORE=$(echo "$ROW" | jq -r '.[0].status')
    PAUSED_REASON=$(echo "$ROW" | jq -r '.[0].paused_reason')
    GOAL_ID=$(echo "$ROW" | jq -r '.[0].goal_id')
    if [[ "$STATUS_BEFORE" = "paused" && "$PAUSED_REASON" != "user" && "$PAUSED_REASON" != "degraded" ]]; then
      echo "goal is paused due to '$PAUSED_REASON'; use /goal-extend or /goal-reconcile" >&2
      exit 3
    fi
    GOAL_ID_ESC=$(sql_escape "$GOAL_ID")
    STATUS_BEFORE_ESC=$(sql_escape "$STATUS_BEFORE")
    NOW=$(ms_now)
    sql "BEGIN IMMEDIATE;
         UPDATE goals SET status='active', paused_reason=NULL,
           resume_at_ms = ${NOW}, version = version + 1, updated_at_ms = ${NOW}
         WHERE session_id = '$SESSION_ID_ESC' AND goal_id = '$GOAL_ID_ESC';
         INSERT INTO goal_events (session_id, goal_id, hook_name, event_type, status_before, status_after, pid, created_at_ms)
         VALUES ('$SESSION_ID_ESC','$GOAL_ID_ESC','goal-cli','goal_resumed','$STATUS_BEFORE_ESC','active',$$,${NOW});
         COMMIT;"
    echo "goal resumed"
    ;;
  abandon)
    ROW=$(sql -json "SELECT goal_id, status FROM goals WHERE session_id = '$SESSION_ID_ESC' AND status NOT IN ('complete','abandoned');")
    [[ -z "$ROW" || "$ROW" == "[]" ]] && { echo "no goal to abandon"; exit 2; }
    GOAL_ID=$(echo "$ROW" | jq -r '.[0].goal_id')
    STATUS_BEFORE=$(echo "$ROW" | jq -r '.[0].status')
    GOAL_ID_ESC=$(sql_escape "$GOAL_ID")
    STATUS_BEFORE_ESC=$(sql_escape "$STATUS_BEFORE")
    NOW=$(ms_now)
    sql "BEGIN IMMEDIATE;
         UPDATE goals SET status='abandoned', paused_reason=NULL,
           time_used_seconds = time_used_seconds + COALESCE((${NOW} - resume_at_ms)/1000, 0),
           resume_at_ms = NULL, version = version + 1, updated_at_ms = ${NOW}
         WHERE session_id = '$SESSION_ID_ESC' AND goal_id = '$GOAL_ID_ESC';
         INSERT INTO goal_events (session_id, goal_id, hook_name, event_type, status_before, status_after, pid, created_at_ms)
         VALUES ('$SESSION_ID_ESC','$GOAL_ID_ESC','goal-cli','goal_abandoned','$STATUS_BEFORE_ESC','abandoned',$$,${NOW});
         COMMIT;"
    echo "goal abandoned"
    ;;
  extend)
    EXTEND_COUNT=0
    [[ -n "${ADD_CONT}" ]] && EXTEND_COUNT=$((EXTEND_COUNT + 1))
    [[ -n "${ADD_HOURS}" ]] && EXTEND_COUNT=$((EXTEND_COUNT + 1))
    [[ -n "${ADD_TOKENS}" ]] && EXTEND_COUNT=$((EXTEND_COUNT + 1))
    if [[ "$EXTEND_COUNT" -ne 1 ]]; then
      echo "error: specify exactly one of --add-continuations N, --add-hours N, or --add-tokens N" >&2
      exit 1
    fi
    if [[ -n "${ADD_CONT}" ]]; then
      if ! is_positive_int "$ADD_CONT"; then
        echo "error: --add-continuations must be a positive integer" >&2
        exit 1
      fi
      UPDATE_RESULT=$(sql "UPDATE goals SET continuations_remaining = continuations_remaining + ${ADD_CONT},
             status = 'active', paused_reason = NULL, resume_at_ms = $(ms_now),
             version = version + 1
           WHERE session_id = '$SESSION_ID_ESC' AND status = 'paused' AND paused_reason = 'continuation_cap';
           SELECT changes();")
      if [[ "$(sql_change_count "$UPDATE_RESULT")" != "1" ]]; then
        echo "no continuation-cap paused goal to extend" >&2
        exit 2
      fi
      echo "added ${ADD_CONT} continuations; resumed"
    elif [[ -n "${ADD_HOURS}" ]]; then
      if ! is_positive_int "$ADD_HOURS"; then
        echo "error: --add-hours must be a positive integer" >&2
        exit 1
      fi
      ADD_SEC=$((ADD_HOURS * 3600))
      UPDATE_RESULT=$(sql "UPDATE goals SET max_wall_clock_seconds = max_wall_clock_seconds + ${ADD_SEC},
             status = 'active', paused_reason = NULL, resume_at_ms = $(ms_now),
             version = version + 1
           WHERE session_id = '$SESSION_ID_ESC' AND status = 'paused' AND paused_reason = 'wall_clock_cap';
           SELECT changes();")
      if [[ "$(sql_change_count "$UPDATE_RESULT")" != "1" ]]; then
        echo "no wall-clock-cap paused goal to extend" >&2
        exit 2
      fi
      echo "added ${ADD_HOURS}h wall clock; resumed"
    elif [[ -n "${ADD_TOKENS}" ]]; then
      if ! is_positive_int "$ADD_TOKENS"; then
        echo "error: --add-tokens must be a positive integer" >&2
        exit 1
      fi
      NOW=$(ms_now)
      UPDATE_RESULT=$(sql "UPDATE goals SET
             token_budget = COALESCE(token_budget, tokens_used + subagent_tokens) + ${ADD_TOKENS},
             budget_profile = CASE WHEN token_budget IS NULL THEN NULL ELSE budget_profile END,
             budget_source = CASE WHEN token_budget IS NULL THEN 'tokens' ELSE budget_source END,
             status = CASE WHEN status = 'budget_limited' THEN 'active' ELSE status END,
             paused_reason = CASE WHEN status = 'budget_limited' THEN NULL ELSE paused_reason END,
             resume_at_ms = CASE WHEN status = 'budget_limited' THEN ${NOW} ELSE resume_at_ms END,
             budget_limit_reported = CASE WHEN status = 'budget_limited' THEN 0 ELSE budget_limit_reported END,
             version = version + 1,
             updated_at_ms = ${NOW}
           WHERE session_id = '$SESSION_ID_ESC' AND status IN ('active','budget_limited');
           SELECT changes();")
      if [[ "$(sql_change_count "$UPDATE_RESULT")" != "1" ]]; then
        echo "no active or budget-limited goal to extend" >&2
        exit 2
      fi
      echo "added ${ADD_TOKENS} token budget; resumed if budget-limited"
    else
      echo "error: specify exactly one of --add-continuations N, --add-hours N, or --add-tokens N" >&2
      exit 1
    fi
    ;;
  history)
    # List goals tracked by this plugin. The goals table stores one row per
    # session_id (PRIMARY KEY), so history is naturally cross-session.
    # Default scope: --current (this session only). Pass --all for every session,
    # or --session-id <id> for a specific past session.
    if [[ "${HISTORY_ALL:-0}" = "1" ]]; then
      WHERE_CLAUSE=""
    else
      WHERE_CLAUSE="WHERE session_id = '$SESSION_ID_ESC'"
    fi
    ROWS=$(sql -json "
      SELECT session_id, goal_id, objective, status, paused_reason,
             tokens_used, subagent_tokens, token_budget, budget_profile, budget_source,
             continuations_remaining,
             time_used_seconds, created_at_ms, updated_at_ms
      FROM goals
      $WHERE_CLAUSE
      ORDER BY created_at_ms DESC;" 2>/dev/null || echo "[]")
    if [[ -z "$ROWS" || "$ROWS" = "[]" ]]; then
      if [[ "$FORMAT" = "json" ]]; then
        echo "[]"
      elif [[ "${HISTORY_ALL:-0}" = "1" ]]; then
        echo "no goals tracked yet"
      else
        echo "no goals for this session (try --all for cross-session history)"
      fi
      exit 0
    fi
    if [[ "$FORMAT" = "json" ]]; then
      echo "$ROWS"
    else
      echo "$ROWS" | jq -r '
        def budget_label:
          if .budget_source == "auto" then "\(.budget_profile) profile (auto)"
          elif .budget_source == "profile" then "\(.budget_profile) profile"
          elif .budget_source == "tokens" then "raw tokens"
          else "unbounded"
          end;
        .[] | "[\(.status)\(if .paused_reason then " (\(.paused_reason))" else "" end)] \(.objective) — budget=\(budget_label), tokens=\(.tokens_used)\(if .token_budget then "/\(.token_budget)" else "" end), subagent_tokens=\(.subagent_tokens // 0), time=\(.time_used_seconds)s, continuations_remaining=\(.continuations_remaining)\n  goal_id=\(.goal_id) session=\(.session_id) created_at_ms=\(.created_at_ms)"'
    fi
    ;;
  reconcile)
    if [[ "${ACCEPT_RESET}" == "1" ]]; then
      NOW=$(ms_now)
      # One-step recovery: clear accounting_uncertain AND, if status='paused' due to
      # 'accounting_error', flip back to active. Otherwise just clear the flag.
      sql "BEGIN IMMEDIATE;
           UPDATE goals SET accounting_uncertain = 0, version = version + 1
             WHERE session_id = '$SESSION_ID_ESC';
           UPDATE goals SET status = 'active', paused_reason = NULL,
             resume_at_ms = $NOW, version = version + 1, updated_at_ms = $NOW
             WHERE session_id = '$SESSION_ID_ESC'
               AND status = 'paused' AND paused_reason = 'accounting_error';
           COMMIT;"
      echo "accounting_uncertain cleared; goal resumed if it was paused for accounting_error"
    else
      echo "use --accept-reset to clear accounting_uncertain flag" >&2
      exit 1
    fi
    ;;
  cleanup)
    if [[ -z "$CLEANUP_ACTION" ]]; then
      echo "error: cleanup requires --list or --delete; optional --older-than HOURS (default 0 for --list, 24 for --delete)" >&2
      exit 1
    fi
    # Use ms_now if available, else inline
    if type -t ms_now >/dev/null; then NOW=$(ms_now)
    elif date +%s%3N 2>/dev/null | grep -q '^[0-9]\+$'; then NOW=$(date +%s%3N)
    else NOW=$(python3 -c "import time; print(int(time.time()*1000))")
    fi
    CUTOFF=$(( NOW - (CLEANUP_HOURS * 3600 * 1000) ))
    if [[ "$CLEANUP_ACTION" = "list" ]]; then
      ROWS=$(sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" \
        "SELECT session_id, goal_id, objective, status,
                (($NOW - updated_at_ms)/3600000) AS hours_stale
         FROM goals WHERE updated_at_ms < $CUTOFF ORDER BY updated_at_ms;" 2>/dev/null || echo "")
      if [[ -z "$ROWS" ]]; then
        echo "no orphan goals older than ${CLEANUP_HOURS}h"
      else
        echo "$ROWS"
      fi
    else
      # delete
      DELETED=$(sqlite3 -bail "$DB_PATH" "SELECT COUNT(*) FROM goals WHERE updated_at_ms < $CUTOFF;" 2>/dev/null || echo "0")
      sqlite3 -bail -cmd ".timeout 5000" "$DB_PATH" "
        BEGIN IMMEDIATE;
        DELETE FROM goal_events WHERE session_id IN (SELECT session_id FROM goals WHERE updated_at_ms < $CUTOFF);
        DELETE FROM continuation_leases WHERE session_id IN (SELECT session_id FROM goals WHERE updated_at_ms < $CUTOFF);
        DELETE FROM subagent_token_cursors WHERE session_id IN (SELECT session_id FROM goals WHERE updated_at_ms < $CUTOFF);
        DELETE FROM goals WHERE updated_at_ms < $CUTOFF;
        COMMIT;
      " >/dev/null 2>&1
      echo "deleted $DELETED orphan goal(s) older than ${CLEANUP_HOURS}h"
    fi
    ;;
  doctor)
    CHECKS='[]'
    add_check() {
      local id="$1" status="$2" detail="${3:-}"
      CHECKS=$(echo "$CHECKS" | jq --arg id "$id" --arg s "$status" --arg d "$detail" \
        '. + [{id:$id, status:$s, detail:$d}]')
    }
    # Plugin data dir writability
    DATA_DIR="${PLUGIN_DATA:-${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/claude-goal}}"
    if [[ -w "$DATA_DIR" ]]; then add_check plugin_data_writable pass "$DATA_DIR"; else add_check plugin_data_writable fail "$DATA_DIR not writable"; fi
    # Schema version
    SV=$(sqlite3 "$DB_PATH" "SELECT version FROM schema_version;" 2>/dev/null || echo "")
    if [[ "$SV" = "5" ]]; then add_check schema_version pass "5"; else add_check schema_version fail "got '$SV'"; fi
    # Dependencies
    for dep in node jq sqlite3 envsubst; do
      if command -v "$dep" >/dev/null 2>&1; then add_check "${dep}_present" pass; else add_check "${dep}_present" fail "$dep not found in PATH"; fi
    done
    # Hook scripts executable
    HOOK_OK=1
    for h in stop post-tool-batch session-start user-prompt-expansion; do
      [[ -x "$SCRIPT_DIR/$h.sh" ]] || HOOK_OK=0
    done
    if [[ $HOOK_OK -eq 1 ]]; then add_check hook_scripts_executable pass; else add_check hook_scripts_executable fail "one or more hook scripts missing or not executable"; fi
    # Stale leases (informational)
    NOW_MS=$(python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null || echo 0)
    STALE=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM continuation_leases WHERE expires_at_ms < ${NOW_MS};" 2>/dev/null || echo 0)
    add_check stale_leases pass "$STALE stale"
    # Active goals (informational)
    ACTIVE=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM goals WHERE status IN ('active','blocked','budget_limited');" 2>/dev/null || echo 0)
    add_check active_goals pass "$ACTIVE active"
    # disableAllHooks: hard fail — without hooks, the entire continuation loop is dead.
    # Check user and project settings; managed-policy settings (system-wide) are skipped
    # because they're outside reliable read perms across platforms.
    HOOKS_DISABLED=""
    for f in "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json" \
             "$PWD/.claude/settings.json" "$PWD/.claude/settings.local.json"; do
      [[ -r "$f" ]] || continue
      if jq -e '.disableAllHooks == true' "$f" >/dev/null 2>&1; then
        HOOKS_DISABLED="$f"
        break
      fi
    done
    if [[ -n "$HOOKS_DISABLED" ]]; then
      add_check hooks_enabled fail "disableAllHooks=true in $HOOKS_DISABLED — claude-goal cannot run; remove the setting or unset to enable the goal loop"
    else
      add_check hooks_enabled pass ""
    fi

    OVERALL=$(echo "$CHECKS" | jq -r 'if (map(select(.status=="fail")) | length) > 0 then "fail" elif (map(select(.status=="warn")) | length) > 0 then "warn" else "pass" end')

    PLATFORM="${OSTYPE:-$(uname)}"
    if [[ "$FORMAT" = "json" ]]; then
      jq -n --arg v "0.2.6" --arg p "$PLATFORM" --argjson c "$CHECKS" --arg o "$OVERALL" \
        '{version:$v, platform:$p, checks:$c, overall:$o}'
    else
      echo "claude-goal doctor: $OVERALL"
      echo "Platform: $PLATFORM"
      echo "$CHECKS" | jq -r '.[] | "  [\(.status)] \(.id)\(if .detail != "" then ": \(.detail)" else "" end)"'
    fi
    [[ "$OVERALL" = "fail" ]] && exit 4 || exit 0
    ;;
  *)
    echo "unknown subcommand: $SUBCMD" >&2
    exit 1
    ;;
esac
