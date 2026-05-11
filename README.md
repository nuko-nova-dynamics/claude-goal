# claude-goal

Codex-style autonomous goal loop for Claude Code. Type `/goal-start "objective"` and the agent self-drives turns until the model passes its own completion audit, the token budget exhausts, or you stop it. Inspired by OpenAI Codex's `/goal` feature.

## vs Claude Code's built-in `/goal`

Claude Code v2.1.139+ ships a native `/goal` command (session-scoped Stop hook + Haiku evaluator). It's the right choice for casual "work until this condition holds" tasks. `claude-goal` is the production-grade alternative when you need more control:

| | Built-in `/goal` (CC 2.1.139+) | `claude-goal` (this plugin) |
|---|---|---|
| Set objective + autonomous continuation | yes | yes |
| Live elapsed/turns/tokens overlay | yes (built-in UI) | via statusline |
| Token budget enforcement | phrase it in the condition | `--budget N`, deterministic |
| Turn cap | phrase it in the condition | 50 default, `--add-continuations N` to extend |
| Wall-clock cap | phrase it in the condition | 4h default, `--add-hours N` to extend |
| Pause / resume / abandon | `/goal clear` only | `/goal-pause`, `/goal-resume`, `/goal-abandon` |
| `/compact` resilience | n/a | `accounting_uncertain` flag + `/goal-reconcile` |
| Cross-session restart persistence | `--resume` resets counters | SQLite preserves counters |
| `/clear` handling | auto-removes goal | orphan + `/goal-cleanup` to reap |
| Preflight self-test | n/a | `/goal-doctor` |
| Completion judgment | fresh Haiku evaluator per turn | model self-audit via `update_goal` (Haiku-evaluator parity tracked for v0.2) |

The two coexist. Use native `/goal` for quick conditions; use this plugin for production autonomous work where budgets, pauses, and recovery matter.

## Quickstart

**Install** (session-local, current working method until marketplace publish):

```bash
claude --plugin-dir /path/to/claude-goal
```

> Note: `claude plugin install --local` requires a marketplace scope not yet available in Claude Code 2.1.x. `--plugin-dir` is the supported alternative. After upgrading the plugin, run `claude restart` to reload the MCP server.

**Install from release tarball:**

```bash
mkdir -p ~/.claude/plugins/local/claude-goal
tar -xzf claude-goal-v0.1.0.tar.gz -C ~/.claude/plugins/local/claude-goal
claude --plugin-dir ~/.claude/plugins/local/claude-goal
```

The tarball ships the prebuilt MCP `dist/` plus pruned production runtime dependencies under `mcp/goal-server/node_modules`, so no package-manager install step is needed on the target machine beyond a Node 22 runtime to execute the server.

**Start a goal:**

```
/goal-start "list all .ts files under src/ and print a line count for each"
```

Expected behavior: Claude confirms the goal, begins working, and continues across turns without further prompting. Each turn the Stop hook injects a continuation prompt. When Claude decides the objective is fully met, it calls `update_goal` with `status: "complete"` and stops.

**With a token budget:**

```
/goal-start "refactor the auth module to use async/await" --budget 50000
```

Claude pauses automatically when `tokens_used` reaches the budget, leaving the goal in `budget_limited` status. Use `/goal-extend` to add more budget.

## Commands

| Command | What it does |
|---|---|
| `/goal-start "objective" [--budget N]` | Start a new autonomous goal. Replaces any prior completed/abandoned goal for this session. |
| `/goal-status` | Show current goal, status, tokens used vs budget, continuations remaining, and any warnings. |
| `/goal-pause` | Pause the goal immediately (user-paused). Claude stops self-driving until you resume. |
| `/goal-resume` | Resume a user-paused goal. |
| `/goal-abandon` | Abandon the current goal permanently. |
| `/goal-extend --add-continuations N` | Add N continuation turns to a `continuation_cap`-paused goal and resume it. |
| `/goal-extend --add-hours N` | Add N hours to a `wall_clock_cap`-paused goal and resume it. |
| `/goal-reconcile --accept-reset` | Clear the `accounting_uncertain` flag set after `/compact`. Resets token accounting to current transcript cursor and resumes if the goal was paused for that reason. |
| `/goal-doctor` | Run a preflight self-test: checks SQLite, MCP connectivity, hook registration, and shell dependencies. |
| `/goal-cleanup --list` | List orphaned goals from sessions where `/clear` was used. Shows all by default; pass `--older-than HOURS` to filter. |
| `/goal-cleanup --delete` | Delete orphaned goals. Defaults to `--older-than 24` to avoid removing fresh paused goals; override with `--older-than HOURS`. |

## How it works

1. **Stop hook — continuation injection.** After every turn, `scripts/stop.sh` fires. If a goal is `active`, the hook emits `{"decision":"block","reason":"<continuation prompt>"}`, which causes Claude Code to feed the prompt back to the model for the next turn. The continuation prompt (adapted from Codex's `continuation.md`) reminds the model of the objective and asks it to either keep working or call `update_goal` when done.

2. **Token accounting.** `scripts/post-tool-batch.sh` fires after every tool batch. It reads the session transcript JSONL, finds the assistant messages since the last recorded cursor, and sums `input_tokens + output_tokens` from each message's usage metadata. Accumulated counts are written to SQLite.

3. **Completion detection.** The Stop hook scans the latest assistant message in the transcript for a `tool_use` block calling `update_goal` with `status: "complete"`. On detection it transitions the goal to `complete` and does **not** inject a continuation prompt.

4. **Budget / cap enforcement.** At the start of each Stop hook run, the hook checks `tokens_used >= token_budget`, `continuations_remaining <= 0`, and elapsed wall-clock time. Any breach transitions the goal to `paused` with the appropriate `paused_reason` before checking for completion.

5. **State store.** All goal state lives in SQLite at `${CLAUDE_PLUGIN_DATA}/goals.db` (WAL mode). The `goals` table records status, token counts, continuation budget, wall-clock usage, and a full audit event log in `goal_events`.

6. **MCP tools.** The bundled MCP server (`mcp/goal-server`) exposes `create_goal`, `get_goal`, and `update_goal`. Slash-command skills invoke `create_goal`; the Stop hook invokes `update_goal` on completion; all other lifecycle operations go through `scripts/goal-cli.sh`.

## Optional statusline

Add a live goal status indicator to the Claude Code status bar. Once `statusline/status.sh` is present (Phase 6.3), add this to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/path/to/claude-goal/statusline/status.sh"
  }
}
```

The script queries the active session's goal from SQLite and prints one of:

- `Pursuing goal (12K / 50K)` — active, with budget
- `Pursuing goal (8K)` — active, no budget
- `Goal paused (user)` — paused by user
- `Goal unmet (budget exhausted)` — budget_limited
- `Goal achieved` — complete

> Note: `statusline/status.sh` is not yet present. It will be added in Phase 6.3.

## Known limitations

- **macOS / Linux / WSL only.** The hooks are bash scripts. Native Windows (cmd.exe / Git Bash without a proper bash layer) triggers a fail-fast guard in `stop.sh`. WSL is best-effort and untested.
- **`/clear` orphans the active goal.** Claude Code's `/clear` creates a new session ID, leaving the old goal's state in SQLite with no session to drive it. Use `/goal-abandon` before clearing. `/goal-cleanup` (Phase 6.4) will list and delete orphans.
- **Subagent token usage is partially counted.** The `PostToolBatch` hook fires on the parent session for subagent tool calls, so subagent activity is accounted for via the parent transcript — same as Codex parity. Dedicated per-subagent cursors are deferred to v0.2.
- **Final turn's tokens at completion are undercounted.** The token accounting catchup runs at the *start* of the Stop hook, before `update_goal` is detected. The completion turn's own token cost is recorded in the *next* hook invocation, which never fires after `complete`. This is tracked as F5 and deferred to v0.2.
- **Auto mode classifier may block `update_goal`.** Claude Code's Auto mode runs a classifier that can reject tool calls from skills if the objective looks like placeholder text. Use concrete, achievable objectives (e.g. `"add a --verbose flag to the CLI"`, not `"do the task"`).
- **Plugin upgrade lifecycle is undocumented.** After updating the plugin files, run `claude restart` to reload the MCP server. Hot-reload behavior is not guaranteed.

## Platform support

| Platform | Status |
|---|---|
| macOS | Tested |
| Linux | Tested |
| WSL (Windows Subsystem for Linux) | Best-effort, untested |
| Native Windows (cmd.exe / Git Bash) | Fail-fast guard — not supported |

## For developers / contributors

- **Design spec:** `docs/superpowers/specs/2026-05-09-claude-goal-design.md`
- **Implementation plan:** `docs/superpowers/plans/2026-05-09-claude-goal-implementation.md`
- **Hook tests:** `tests/` — 79 bats test cases across 12 `.bats` files
- **MCP tests:** `mcp/goal-server/test/` — 32 Vitest test cases across 4 test files

Run hook tests:

```bash
bats tests/
```

Run MCP tests:

```bash
cd mcp/goal-server && pnpm test
```

## Acknowledgments

The autonomous loop mechanism — Stop hook injecting a continuation prompt, model self-driving until a completion signal — is ported from OpenAI Codex's `/goal` feature (`codex-rs`). The `continuation.md` and `budget-limit.md` prompt templates in `prompts/` are adapted from Codex's `core/templates/goals/` with minor modifications for Claude Code's hook API.
