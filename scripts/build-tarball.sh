#!/usr/bin/env bash
set -euo pipefail

# Build a distribution tarball for claude-goal release.
# Reads the version from .claude-plugin/plugin.json so a single source of truth
# stays the manifest.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION="$(jq -r '.version' .claude-plugin/plugin.json)"
OUT="claude-goal-v${VERSION}.tar.gz"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Make sure the MCP server is built so dist/ ships.
(cd mcp/goal-server && npm run build >/dev/null)

# Stage an installable plugin tree. The MCP entrypoint runs from dist/index.js
# and depends on runtime packages resolved from mcp/goal-server/node_modules.
# Keep those dependencies in the tarball so a clean target profile does not
# need the source repo or a package-manager install step.
mkdir -p "$STAGE/mcp/goal-server"
cp -R .claude-plugin .mcp.json agents hooks scripts skills prompts statusline README.md RELEASE_NOTES.md ROADMAP.md LICENSE "$STAGE/"
cp mcp/goal-server/package.json mcp/goal-server/package-lock.json "$STAGE/mcp/goal-server/"
cp -R mcp/goal-server/dist mcp/goal-server/node_modules "$STAGE/mcp/goal-server/"

(cd "$STAGE/mcp/goal-server" && npm prune --omit=dev >/dev/null)
rm -rf "$STAGE/mcp/goal-server/node_modules/.vite" "$STAGE/mcp/goal-server/node_modules/.cache"

tar \
    --exclude='.git' \
    --exclude='*.db' \
    --exclude='*.db-shm' \
    --exclude='*.db-wal' \
    -czf "$OUT" \
    -C "$STAGE" \
    .claude-plugin .mcp.json agents hooks scripts skills prompts statusline \
    mcp README.md RELEASE_NOTES.md ROADMAP.md LICENSE

echo "built $OUT ($(du -h "$OUT" | cut -f1), $(tar -tzf "$OUT" | wc -l | tr -d ' ') entries)"
