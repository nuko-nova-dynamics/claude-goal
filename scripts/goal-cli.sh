#!/usr/bin/env bash
# Usage: goal-cli.sh <subcommand> [args...]
# Subcommands: status, pause, resume, abandon, extend, reconcile, doctor
# Reads CLAUDE_SESSION_ID from environment if available; else from --session-id flag.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/sqlite-retry.sh"
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
ACCEPT_RESET=0

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
    --accept-reset) ACCEPT_RESET=1; shift ;;
    *) shift ;;
  esac
done

# Resolver order: --session-id flag → CLAUDE_SESSION_ID env → marker file → error
if [[ -z "$SESSION_ID" && -n "$PLUGIN_ROOT" && -f "$PLUGIN_ROOT/.runtime-session-id" ]]; then
  SESSION_ID=$(cat "$PLUGIN_ROOT/.runtime-session-id")
fi

# doctor doesn't need session_id; check per-subcommand
case "$SUBCMD" in
  doctor) ;;
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

case "$SUBCMD" in
  status)
    ROW=$(sql -json "SELECT * FROM goals WHERE session_id = '$SESSION_ID_ESC';")
    if [[ -z "$ROW" || "$ROW" == "[]" ]]; then
      [[ "$FORMAT" == "json" ]] && echo '{"goal":null}' || echo "no goal for this session"
      exit 2
    fi
    # Compute remaining_tokens and convert accounting_uncertain to bool per spec Appendix A.1
    ENRICHED=$(echo "$ROW" | jq '.[0]
      | .remaining_tokens = (if .token_budget then ((.token_budget - .tokens_used) | if . < 0 then 0 else . end) else null end)
      | .accounting_uncertain = (.accounting_uncertain == 1)')
    if [[ "$FORMAT" == "json" ]]; then
      echo "$ENRICHED"
    else
      echo "$ENRICHED" | jq -r '"Goal: \(.objective)\nStatus: \(.status)\(if .paused_reason then " (\(.paused_reason))" else "" end)\nTokens: \(.tokens_used)\(if .token_budget then " / \(.token_budget) (\(.remaining_tokens) remaining)" else "" end)\nTime: \(.time_used_seconds)s\nContinuations remaining: \(.continuations_remaining)\(if .accounting_uncertain then "\nWARNING: accounting uncertain — see /goal-reconcile" else "" end)"'
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
    ROW=$(sql -json "SELECT goal_id, paused_reason FROM goals WHERE session_id = '$SESSION_ID_ESC' AND status = 'paused';")
    [[ -z "$ROW" || "$ROW" == "[]" ]] && { echo "no paused goal to resume"; exit 2; }
    PAUSED_REASON=$(echo "$ROW" | jq -r '.[0].paused_reason')
    GOAL_ID=$(echo "$ROW" | jq -r '.[0].goal_id')
    if [[ "$PAUSED_REASON" != "user" && "$PAUSED_REASON" != "degraded" ]]; then
      echo "goal is paused due to '$PAUSED_REASON'; use /goal-extend or /goal-reconcile" >&2
      exit 3
    fi
    GOAL_ID_ESC=$(sql_escape "$GOAL_ID")
    NOW=$(ms_now)
    sql "BEGIN IMMEDIATE;
         UPDATE goals SET status='active', paused_reason=NULL,
           resume_at_ms = ${NOW}, version = version + 1, updated_at_ms = ${NOW}
         WHERE session_id = '$SESSION_ID_ESC' AND goal_id = '$GOAL_ID_ESC';
         INSERT INTO goal_events (session_id, goal_id, hook_name, event_type, status_before, status_after, pid, created_at_ms)
         VALUES ('$SESSION_ID_ESC','$GOAL_ID_ESC','goal-cli','goal_resumed','paused','active',$$,${NOW});
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
         UPDATE goals SET status='abandoned',
           time_used_seconds = time_used_seconds + COALESCE((${NOW} - resume_at_ms)/1000, 0),
           resume_at_ms = NULL, version = version + 1, updated_at_ms = ${NOW}
         WHERE session_id = '$SESSION_ID_ESC' AND goal_id = '$GOAL_ID_ESC';
         INSERT INTO goal_events (session_id, goal_id, hook_name, event_type, status_before, status_after, pid, created_at_ms)
         VALUES ('$SESSION_ID_ESC','$GOAL_ID_ESC','goal-cli','goal_abandoned','$STATUS_BEFORE_ESC','abandoned',$$,${NOW});
         COMMIT;"
    echo "goal abandoned"
    ;;
  extend)
    if [[ -n "${ADD_CONT}" ]]; then
      sql "UPDATE goals SET continuations_remaining = continuations_remaining + ${ADD_CONT},
             status = 'active', paused_reason = NULL, resume_at_ms = $(ms_now),
             version = version + 1
           WHERE session_id = '$SESSION_ID_ESC' AND status = 'paused' AND paused_reason = 'continuation_cap';"
      echo "added ${ADD_CONT} continuations; resumed"
    elif [[ -n "${ADD_HOURS}" ]]; then
      ADD_SEC=$((ADD_HOURS * 3600))
      sql "UPDATE goals SET max_wall_clock_seconds = max_wall_clock_seconds + ${ADD_SEC},
             status = 'active', paused_reason = NULL, resume_at_ms = $(ms_now),
             version = version + 1
           WHERE session_id = '$SESSION_ID_ESC' AND status = 'paused' AND paused_reason = 'wall_clock_cap';"
      echo "added ${ADD_HOURS}h wall clock; resumed"
    else
      echo "error: must specify --add-continuations N or --add-hours N" >&2
      exit 1
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
    if [[ "$SV" = "1" ]]; then add_check schema_version pass "1"; else add_check schema_version fail "got '$SV'"; fi
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
    ACTIVE=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM goals WHERE status IN ('active','budget_limited');" 2>/dev/null || echo 0)
    add_check active_goals pass "$ACTIVE active"

    OVERALL=$(echo "$CHECKS" | jq -r 'if (map(select(.status=="fail")) | length) > 0 then "fail" elif (map(select(.status=="warn")) | length) > 0 then "warn" else "pass" end')

    PLATFORM="${OSTYPE:-$(uname)}"
    if [[ "$FORMAT" = "json" ]]; then
      jq -n --arg v "0.1.0" --arg p "$PLATFORM" --argjson c "$CHECKS" --arg o "$OVERALL" \
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
