#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  VERSION="$(jq -r '.version' "$REPO_ROOT/.claude-plugin/plugin.json")"
  OUT="$REPO_ROOT/claude-goal-v${VERSION}.tar.gz"
}

@test "release tarball includes MCP runtime dependencies" {
  run "$REPO_ROOT/scripts/build-tarball.sh"
  [ "$status" -eq 0 ]

  ENTRIES="$(tar -tzf "$OUT")"
  [[ "$ENTRIES" == *"mcp/goal-server/dist/index.js"* ]]
  [[ "$ENTRIES" == *"mcp/goal-server/node_modules/@modelcontextprotocol/sdk/package.json"* ]]
  [[ "$ENTRIES" == *"mcp/goal-server/node_modules/better-sqlite3/package.json"* ]]
  [[ "$ENTRIES" == *"agents/goal-evaluator.md"* ]]
}
