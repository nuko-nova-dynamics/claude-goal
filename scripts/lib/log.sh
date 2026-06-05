#!/usr/bin/env bash
# Source this; provides log_info / log_error to per-day log files under
# ${CLAUDE_PLUGIN_DATA}/logs/. Falls back to a safe directory if CLAUDE_PLUGIN_DATA
# is unset (early-boot or test environments).
LOG_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/claude-goal-NULL}/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/$(date -u +%Y%m%d).log"

log_info()  { echo "[$(date -u +%FT%TZ)] [INFO] $*"  >> "$LOG_FILE" 2>/dev/null || true; }
log_error() { echo "[$(date -u +%FT%TZ)] [ERROR] $*" >> "$LOG_FILE" 2>/dev/null || true; }
