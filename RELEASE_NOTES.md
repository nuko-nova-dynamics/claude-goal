# claude-goal v0.1.0

A Claude Code plugin that ports OpenAI Codex's `/goal` autonomous loop. Type `/goal-start "objective"` and the agent self-drives turns until the model passes its own completion audit, the token budget exhausts, or a cap fires.

**Compatible with Claude Code 2.1.139+'s built-in `/goal`** (which shipped the same day, May 11 2026). The two coexist — use native `/goal` for casual conditions, use this plugin's `/goal-start` for token budgets, pause/resume, `/compact` recovery, and persistence across `claude` restart.

This is a **public beta**. The happy path is real-Claude-validated end-to-end across 5 acceptance scenarios, but it has not yet accumulated outside-user miles. Please file issues against anything surprising.

## What's in v0.1.0

### Commands

`/goal-start "objective" [--budget N]` · `/goal-status` · `/goal-pause` · `/goal-resume` · `/goal-abandon` (`/goal-stop` alias) · `/goal-extend --add-continuations N | --add-hours N` · `/goal-reconcile --accept-reset` · `/goal-doctor` · `/goal-history [--all] [--format=json]` · `/goal-cleanup --list | --delete [--older-than HOURS]`

### How it works

1. **Stop hook** injects a continuation prompt via `{"decision":"block","reason":"..."}` after every turn, driving the model to self-iterate.
2. **PostToolBatch hook** sums `input_tokens + cache_creation_input_tokens + output_tokens` from transcript JSONL usage fields. Cache-read is excluded. Parent-worker turns write `tokens_used`; subagent turns write `subagent_tokens` through per-agent cursors.
3. **MCP server** (`mcp/goal-server`) exposes `create_goal`, `get_goal`, `update_goal`. Schema in SQLite with WAL mode, downgrade-protection, optimistic-version concurrency guard, and v2 subagent cursor migration.
4. **Completion detection** uses a dual path: worker self-audit can call `update_goal`, and the worker is instructed to dispatch the plugin subagent `claude-goal:goal-evaluator` before marking complete. Completion events distinguish `goal_completed_by_self_update` from `goal_completed_by_evaluator`.
5. **Budget / cap enforcement** transitions goals to `budget_limited`, `paused` (`continuation_cap`, `wall_clock_cap`), or `degraded` on catch-all errors. Budget math uses worker + subagent tokens.

### Empirically verified

- 20 Phase-0 probes resolved (18 pass · 1 skip · 1 unclear)
- 5 real-Claude acceptance scenarios via Codex computer-use smoke
- F5 final-turn token accounting after completion
- Evaluator subagent dispatch and per-subagent token attribution under `claude -p`
- Stop hook stdin contract (no `tool_calls` field — completion read from transcript JSONL)
- v1→v2 schema migration probe and transactional v2 migration tests
- Cold-start install from fresh clone and from release tarball
- macOS, Linux

### Tests

129 bats + 59 Vitest = **188 green**. GitHub Actions CI on Ubuntu.

## Install

### From the release tarball

```bash
mkdir -p ~/.claude/plugins/local/claude-goal
tar -xzf claude-goal-v0.1.0.tar.gz -C ~/.claude/plugins/local/claude-goal
claude --plugin-dir ~/.claude/plugins/local/claude-goal
```

The tarball ships the prebuilt MCP `dist/`, pruned production dependencies under `mcp/goal-server/node_modules/`, `LICENSE`, and `RELEASE_NOTES.md`. No package-manager install needed on the target machine beyond a Node 22 runtime.

### From git (development)

```bash
git clone https://github.com/nuko-nova-dynamics/claude-goal.git
cd claude-goal
(cd mcp/goal-server && npm ci && npm run build)
claude --plugin-dir "$PWD"
```

## Known limitations

- **macOS / Linux / WSL only.** Native Windows triggers a fail-fast guard in `stop.sh`. WSL is best-effort.
- **Auto mode classifier may block `update_goal`.** Use concrete, achievable objectives.
- **`/clear` orphans the active goal.** New session ID leaves the old goal as an orphan row. Use `/goal-cleanup --list` / `--delete` to surface and reap.
- **Final-turn accounting is bounded.** F5 catches late completion-turn transcript flushes with five 100ms retries. If Claude Code flushes completion usage after that window, a tiny residual undercount is still possible.
- **Remote Control dedicated smoke is deferred.** The `-p` headless path is validated; Remote Control advertises the same hook surface but remains an interactive v0.1.1 hardening smoke.
- **Plugin upgrade lifecycle.** Run `claude restart` after updating plugin files; hot-reload is not guaranteed.

## Acknowledgments

The autonomous loop mechanism — Stop hook injecting a continuation prompt, model self-driving until a completion signal — is ported from OpenAI Codex's `/goal` feature (`codex-rs`). The `continuation.md` and `budget-limit.md` prompt templates in `prompts/` are adapted from Codex's `core/templates/goals/` with minor modifications for Claude Code's hook API.

## License

MIT
