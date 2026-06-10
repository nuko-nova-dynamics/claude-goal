#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/sqlite-retry.sh"
source "$SCRIPT_DIR/lib/schema.sh"
source "$SCRIPT_DIR/lib/accounting-core.sh"

# ---------------------------------------------------------------------------
# Platform guard: native Windows (msys/cygwin/MINGW) is not supported.
# WSL runs as Linux and is best-effort.
# ---------------------------------------------------------------------------
case "${OSTYPE:-$(uname)}" in
  msys*|cygwin*|MINGW*)
    log_error "claude-goal v1 requires bash; not supported on Windows native"
    echo '{"systemMessage":"claude-goal v1 requires bash and is not supported on Windows native. WSL is best-effort."}'
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# DB path resolution: marker file primary, env fallback.
# Mirrors the inverted resolver pattern from Phase 2.10.
# ---------------------------------------------------------------------------
PLUGIN_DATA="${CLAUDE_PLUGIN_DATA:-}"
if [[ -z "$PLUGIN_DATA" && -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "${CLAUDE_PLUGIN_ROOT}/.runtime-data-dir" ]]; then
  PLUGIN_DATA=$(cat "${CLAUDE_PLUGIN_ROOT}/.runtime-data-dir" 2>/dev/null || echo "")
fi
if [[ -z "$PLUGIN_DATA" ]]; then
  PLUGIN_DATA="$HOME/.claude/plugins/data/claude-goal"
fi

DB_PATH="${DB_PATH:-$PLUGIN_DATA/goals.db}"

# ---------------------------------------------------------------------------
# Preflight: plugin data dir must be writable.
# On failure emit a systemMessage and exit clean (degraded mode).
# ---------------------------------------------------------------------------
mkdir -p "$PLUGIN_DATA" 2>/dev/null
if ! touch "$PLUGIN_DATA/.preflight-test" 2>/dev/null; then
  echo "{\"systemMessage\":\"claude-goal: ${CLAUDE_PLUGIN_DATA} not writable; goal logic skipped\"}"
  exit 0
fi
rm -f "$PLUGIN_DATA/.preflight-test"

# ---------------------------------------------------------------------------
# Log housekeeping: delete log files older than 30 days.
# ---------------------------------------------------------------------------
LOG_DIR="$PLUGIN_DATA/logs"
[[ -d "$LOG_DIR" ]] && find "$LOG_DIR" -type f -name '*.log' -mtime +30 -delete 2>/dev/null || true

# ---------------------------------------------------------------------------
# Parse stdin (hook payload).
# ---------------------------------------------------------------------------
INPUT=$(cat 2>/dev/null || echo "")
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || echo "")
SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"' 2>/dev/null || echo "startup")

# ---------------------------------------------------------------------------
# Write runtime markers (Phase 2.8 / 2.9 logic — preserve).
# These allow Bash-tool subprocesses to locate the data dir and session.
# ---------------------------------------------------------------------------
if [[ -n "${CLAUDE_PLUGIN_DATA:-}" && -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
  printf '%s' "$CLAUDE_PLUGIN_DATA" > "${CLAUDE_PLUGIN_ROOT}/.runtime-data-dir" 2>/dev/null || true
fi
if [[ -n "${SESSION_ID:-}" && -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
  printf '%s' "$SESSION_ID" > "${CLAUDE_PLUGIN_ROOT}/.runtime-session-id" 2>/dev/null || true
fi

log_info "session-start.sh fired (source=$SOURCE)"

# ---------------------------------------------------------------------------
# Early exits: no session_id or no DB yet → nothing to do in DB.
# ---------------------------------------------------------------------------
[[ -z "$SESSION_ID" ]] && exit 0
[[ ! -f "$DB_PATH" ]] && exit 0
if ! ensure_schema_current; then
  log_error "session-start: schema migration guard failed for $DB_PATH"
  echo '{"systemMessage":"claude-goal: database schema migration failed; run /goal-doctor and reload/update the plugin."}'
  exit 0
fi

SESSION_ID_ESC=$(sql_escape "$SESSION_ID")
NOW=$(ms_now)

# v0.2.5 compatibility: recover rows paused by the old per-message usage caps.
recover_legacy_usage_cap_pause "$SESSION_ID" "session-start" >/dev/null 2>&1 || true

# Look up the goal for this session_id.
ROW=$(sql_retry "SELECT goal_id, status, COALESCE(resume_at_ms,0), version FROM goals WHERE session_id = '$SESSION_ID_ESC' LIMIT 1;" 2>/dev/null || echo "")
if [[ -z "$ROW" ]]; then
  if [[ "$SOURCE" = "clear" ]]; then
    log_info "session-start: source=clear — orphan policy; not touching DB (session_id=$SESSION_ID)"
  fi
  exit 0   # no goal for this session — nothing to do
fi

GOAL_ID=$(printf '%s' "$ROW" | cut -d'|' -f1)
STATUS=$(printf '%s' "$ROW"  | cut -d'|' -f2)
RESUME_AT=$(printf '%s' "$ROW" | cut -d'|' -f3)
VERSION=$(printf '%s' "$ROW"  | cut -d'|' -f4)

GOAL_ID_ESC=$(sql_escape "$GOAL_ID")

# ---------------------------------------------------------------------------
# Branch on source
# ---------------------------------------------------------------------------
case "$SOURCE" in
  startup)
    # Markers already written above. No DB changes needed.
    exit 0
    ;;

  resume)
    # The goal continues naturally on the next Stop hook.
    # Log the resume event and update resume_at_ms so elapsed accounting
    # starts fresh from this reconnect point.
    if [[ "$STATUS" = "active" || "$STATUS" = "budget_limited" ]]; then
      sql_retry "UPDATE goals SET resume_at_ms = $NOW, version = version + 1, updated_at_ms = $NOW
                 WHERE session_id = '$SESSION_ID_ESC' AND version = $VERSION;
                 INSERT INTO goal_events
                   (session_id, goal_id, hook_name, event_type, status_before, status_after, pid, created_at_ms)
                 VALUES ('$SESSION_ID_ESC', '$GOAL_ID_ESC', 'session-start', 'session_resumed',
                   '$STATUS', '$STATUS', $$, $NOW);" >/dev/null || true
      log_info "session-start: resumed session with active goal goal_id=$GOAL_ID"
    fi
    ;;

  clear)
    # ---------------------------------------------------------------------------
    # v3 spec §4.7 ORPHAN POLICY:
    # /clear creates a NEW session_id. The SessionStart hook fires with the NEW
    # session_id, which has no goal yet → the ROW lookup above already exited.
    # If we somehow arrive here (same session_id still active at /clear time),
    # that is unexpected. Log it but do NOT modify the goal. The orphan row will
    # be cleaned up by /goal-cleanup.
    # ---------------------------------------------------------------------------
    log_info "session-start: source=clear — orphan policy; not touching DB (session_id=$SESSION_ID)"
    ;;

  compact)
    # Same session_id, but the transcript was rewritten/compacted.
    # Flag accounting_uncertain=1 so /goal-status warns the user.
    # The cursor-reset path handles the actual recompute in a later phase.
    if [[ "$STATUS" = "active" || "$STATUS" = "budget_limited" ]]; then
      sql_retry "UPDATE goals SET accounting_uncertain = 1, version = version + 1, updated_at_ms = $NOW
                 WHERE session_id = '$SESSION_ID_ESC' AND version = $VERSION;
                 INSERT INTO goal_events
                   (session_id, goal_id, hook_name, event_type, status_before, status_after, pid, created_at_ms)
                 VALUES ('$SESSION_ID_ESC', '$GOAL_ID_ESC', 'session-start', 'compact_uncertainty_flagged',
                   '$STATUS', '$STATUS', $$, $NOW);" >/dev/null || true
      echo '{"systemMessage":"goal accounting flagged uncertain after /compact; run /goal-status for details"}'
      log_info "session-start: compact flagged accounting_uncertain on goal_id=$GOAL_ID"
    fi
    ;;

  *)
    log_info "session-start: unknown source=$SOURCE; treating as startup"
    ;;
esac

exit 0
