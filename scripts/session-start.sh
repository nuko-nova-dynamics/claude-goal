#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"
INPUT=$(cat 2>/dev/null || echo "")
SOURCE=$(echo "$INPUT" | jq -r '.source // "unknown"' 2>/dev/null || echo unknown)
log_info "session-start.sh fired (source=$SOURCE)"
exit 0
