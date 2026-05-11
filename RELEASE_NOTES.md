# claude-goal v0.1.0

A Claude Code plugin that ports OpenAI Codex's `/goal` autonomous loop. Type `/goal-start "objective"` and the agent self-drives turns until the model passes its own completion audit, the token budget exhausts, or a cap fires.

**Compatible with Claude Code 2.1.139+'s built-in `/goal`** (which shipped the same day, May 11 2026). The two coexist — use native `/goal` for casual conditions, use this plugin's `/goal-start` for token budgets, pause/resume, `/compact` recovery, and persistence across `claude` restart.

This is a **public beta**. The happy path is real-Claude-validated end-to-end across 5 acceptance scenarios, but it has not yet accumulated outside-user miles. Please file issues against anything surprising.

## What's in v0.1.0

### Commands

`/goal "objective" [--budget N]` · `/goal-status` · `/goal-pause` · `/goal-resume` · `/goal-abandon` · `/goal-extend --add-continuations N | --add-hours N` · `/goal-reconcile --accept-reset` · `/goal-doctor` · `/goal-cleanup --list | --delete [--older-than HOURS]`

### How it works

1. **Stop hook** injects a continuation prompt via `{"decision":"block","reason":"..."}` after every turn, driving the model to self-iterate.
2. **PostToolBatch hook** sums `input_tokens + cache_creation_input_tokens + output_tokens` from transcript JSONL usage fields. Cache-read excluded.
3. **MCP server** (`mcp/goal-server`) exposes `create_goal`, `get_goal`, `update_goal`. Schema in SQLite with WAL mode, downgrade-protection, optimistic-version concurrency guard.
4. **Completion detection** scans the latest assistant message for a `tool_use` call of `update_goal` with `status: "complete"`. The Stop hook stays silent when detected.
5. **Budget / cap enforcement** transitions goals to `budget_limited`, `paused` (`continuation_cap`, `wall_clock_cap`), or `degraded` on catch-all errors.

### Empirically verified

- 20 Phase-0 probes resolved (18 pass · 1 skip · 1 unclear)
- 5 real-Claude acceptance scenarios via Codex computer-use smoke
- Stop hook stdin contract (no `tool_calls` field — completion read from transcript JSONL)
- v1→v2 schema migration probe (P15)
- Cold-start install from fresh clone and from release tarball
- macOS, Linux

### Tests

102 bats + 48 Vitest = **150 green**. GitHub Actions CI on Ubuntu.

## Install

### From the release tarball

```bash
mkdir -p ~/.claude/plugins/local/claude-goal
tar -xzf claude-goal-v0.1.0.tar.gz -C ~/.claude/plugins/local/claude-goal
claude --plugin-dir ~/.claude/plugins/local/claude-goal
```

The tarball ships the prebuilt MCP `dist/` plus pruned production dependencies under `mcp/goal-server/node_modules/`. No package-manager install needed on the target machine beyond a Node 22 runtime.

### From git (development)

```bash
git clone https://github.com/nuko-nova-dynamics/claude-goal.git
cd claude-goal
(cd mcp/goal-server && npm ci && npm run build)
claude --plugin-dir "$PWD"
```

## Known limitations

- **Final turn's tokens at completion are undercounted.** Token accounting catchup runs at the start of the Stop hook, before `update_goal` is detected. Tracked as F5, deferred to v0.2.
- **Subagent token usage is partially counted.** PostToolBatch fires on the parent for subagent tool calls, so subagent activity rolls into parent. Per-subagent cursors deferred to v0.2.
- **macOS / Linux / WSL only.** Native Windows triggers a fail-fast guard in `stop.sh`. WSL is best-effort.
- **Auto mode classifier may block `update_goal`.** Use concrete, achievable objectives.
- **`/clear` orphans the active goal.** New session ID leaves the old goal as an orphan row. Use `/goal-cleanup --list` / `--delete` to surface and reap.
- **Plugin upgrade lifecycle.** Run `claude restart` after updating plugin files; hot-reload is not guaranteed.

## Acknowledgments

The autonomous loop mechanism — Stop hook injecting a continuation prompt, model self-driving until a completion signal — is ported from OpenAI Codex's `/goal` feature (`codex-rs`). The `continuation.md` and `budget-limit.md` prompt templates in `prompts/` are adapted from Codex's `core/templates/goals/` with minor modifications for Claude Code's hook API.

## License

MIT
