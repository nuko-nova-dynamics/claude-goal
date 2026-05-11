# claude-goal

Codex-style `/goal` autonomous loop for Claude Code. Status: in development.

## Install (development / Phase 1)

```bash
# 1. Build the MCP server
cd <repo>/mcp/goal-server
npm install
npm run build
cd <repo>

# 2. Start a session with the plugin loaded
claude --plugin-dir <repo>
```

Notes:
- Claude Code 2.1.138 does not support `claude plugin install --local <path>` (the supported `--scope` flag requires a marketplace). Session-local `--plugin-dir` is the working install path until we publish to a marketplace.
- The plugin's data directory under `~/.claude/plugins/data/` may be named `claude-goal-inline` when loaded via `--plugin-dir`, vs `claude-goal-...` from a marketplace install. Hook logs land under whichever directory CC chooses; the plugin itself reads `${CLAUDE_PLUGIN_DATA}` and doesn't care about the suffix.

See `docs/superpowers/specs/2026-05-09-claude-goal-design.md` for the design and `docs/superpowers/plans/2026-05-09-claude-goal-implementation.md` for the implementation plan.
