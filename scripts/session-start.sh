#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

# Persist the resolved CLAUDE_PLUGIN_DATA to a marker file so subprocesses
# (e.g., the Bash tool running goal-cli.sh) that don't inherit this env var
# can still locate the same DB the MCP server uses. CLAUDE_PLUGIN_ROOT is
# consistently propagated; CLAUDE_PLUGIN_DATA is not.
if [[ -n "${CLAUDE_PLUGIN_DATA:-}" && -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
  printf '%s' "$CLAUDE_PLUGIN_DATA" > "${CLAUDE_PLUGIN_ROOT}/.runtime-data-dir" 2>/dev/null || true
fi

INPUT=$(cat 2>/dev/null || echo "")
SOURCE=$(echo "$INPUT" | jq -r '.source // "unknown"' 2>/dev/null || echo unknown)
log_info "session-start.sh fired (source=$SOURCE)"
exit 0
