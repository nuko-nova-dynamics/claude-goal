#!/usr/bin/env bash
# Usage: goal-cli.sh <subcommand> [args...]
# Subcommands: status, pause, resume, abandon, extend, reconcile, doctor
# Reads CLAUDE_SESSION_ID from environment if available; else from --session-id flag.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

# DB_PATH may be pre-set by tests; otherwise resolve plugin data dir via:
#   1. Runtime marker written by session-start.sh on session boot
#   2. CLAUDE_PLUGIN_DATA env (fallback; can leak across plugin contexts)
#   3. Hardcoded fallback (last resort; likely wrong, but better than crashing)
if [[ -z "${DB_PATH:-}" ]]; then
  if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "${CLAUDE_PLUGIN_ROOT}/.runtime-data-dir" ]]; then
    PLUGIN_DATA=$(cat "${CLAUDE_PLUGIN_ROOT}/.runtime-data-dir")
  elif [[ -n "${CLAUDE_PLUGIN_DATA:-}" ]]; then
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
if [[ -z "$SESSION_ID" && -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "${CLAUDE_PLUGIN_ROOT}/.runtime-session-id" ]]; then
  SESSION_ID=$(cat "${CLAUDE_PLUGIN_ROOT}/.runtime-session-id")
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

# SQL escape for safe interpolation (Phase 3 will move to lib/sqlite-retry.sh)
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
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
    GOAL_ID=$(sql "SELECT goal_id FROM goals WHERE session_id = '$SESSION_ID_ESC' AND status IN ('active','budget_limited');")
    [[ -z "$GOAL_ID" ]] && { echo "no active goal to pause"; exit 2; }
    NOW=$(ms_now)
    sql "BEGIN IMMEDIATE;
         UPDATE goals SET status='paused', paused_reason='user',
           time_used_seconds = time_used_seconds + COALESCE((${NOW} - resume_at_ms)/1000, 0),
           resume_at_ms = NULL, version = version + 1, updated_at_ms = ${NOW}
         WHERE session_id = '$SESSION_ID_ESC' AND goal_id = '$GOAL_ID';
         INSERT INTO goal_events (session_id, goal_id, hook_name, event_type, status_after, pid, created_at_ms)
         VALUES ('$SESSION_ID_ESC','$GOAL_ID','goal-cli','goal_paused','paused',$$,${NOW});
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
    NOW=$(ms_now)
    sql "UPDATE goals SET status='active', paused_reason=NULL,
           resume_at_ms = ${NOW}, version = version + 1, updated_at_ms = ${NOW}
         WHERE session_id = '$SESSION_ID_ESC' AND goal_id = '$GOAL_ID';"
    echo "goal resumed"
    ;;
  abandon)
    GOAL_ID=$(sql "SELECT goal_id FROM goals WHERE session_id = '$SESSION_ID_ESC' AND status NOT IN ('complete','abandoned');")
    [[ -z "$GOAL_ID" ]] && { echo "no goal to abandon"; exit 2; }
    NOW=$(ms_now)
    sql "UPDATE goals SET status='abandoned',
           time_used_seconds = time_used_seconds + COALESCE((${NOW} - resume_at_ms)/1000, 0),
           resume_at_ms = NULL, version = version + 1, updated_at_ms = ${NOW}
         WHERE session_id = '$SESSION_ID_ESC' AND goal_id = '$GOAL_ID';"
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
    echo "claude-goal doctor: TODO (Phase 6)"
    ;;
  *)
    echo "unknown subcommand: $SUBCMD" >&2
    exit 1
    ;;
esac
