#!/usr/bin/env bash
set -euo pipefail

# Build a distribution tarball for claude-goal release.
# Reads the version from .claude-plugin/plugin.json so a single source of truth
# stays the manifest.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION="$(jq -r '.version' .claude-plugin/plugin.json)"
OUT="claude-goal-v${VERSION}.tar.gz"

# Make sure the MCP server is built so dist/ ships
(cd mcp/goal-server && npm run build >/dev/null)

tar --exclude='node_modules' \
    --exclude='.git' \
    --exclude='*.db' \
    --exclude='*.db-shm' \
    --exclude='*.db-wal' \
    --exclude='tests/fixtures/transcripts/captured' \
    -czf "$OUT" \
    .claude-plugin .mcp.json hooks/ scripts/ skills/ prompts/ statusline/ \
    mcp/goal-server/package.json mcp/goal-server/dist/ \
    README.md docs/

echo "built $OUT ($(du -h "$OUT" | cut -f1), $(tar -tzf "$OUT" | wc -l | tr -d ' ') entries)"
