# claude-goal v0.2.6

**Large-run envelopes and no hidden short defaults.**

This release makes goal budgets match modern Claude Code usage. Omitted budgets and raw-token budgets now use practical-unlimited turn/time sentinels instead of hidden 50-turn / 4-hour defaults. Smart profiles are much larger:

- `quick`: 2M tokens, 50 continuations, 2 hours
- `standard`: 10M tokens, 200 continuations, 8 hours
- `deep`: 100M tokens, 1,000 continuations, 24 hours
- `overnight`: 1B tokens, 5,000 continuations, 72 hours

Runtime changes:

- SQLite schema moves to v5 and rebuilds the `goals` table with practical-unlimited defaults for direct inserts too.
- Existing profile rows are lifted to the new minimum envelopes, including in-progress or modestly extended rows.
- Existing unprofiled/raw-token rows are lifted to practical-unlimited turn/time envelopes.
- Existing `budget_limited` profile rows resume automatically when the raised profile budget now exceeds recorded usage.
- Hook/CLI paths run a narrow v4->v5 migration guard before reading goal state; if migration fails, hooks fail closed with a visible degraded message instead of enforcing stale caps.

Verification target:

- `npm --prefix mcp/goal-server test`
- `npm --prefix mcp/goal-server run build`
- `bats $(find tests -name '*.bats' | sort)`
- `npm --prefix docs run build`
- `claude plugin validate .`
- `git diff --check`

# claude-goal v0.2.5

**Large-token accounting fix.**

This release fixes the bug where deep goals could pause immediately with `paused_reason=accounting_error` because a single Claude usage field exceeded a hardcoded 200K-style accounting cap.

## Fixed

- Removed the practical per-message caps on `input_tokens`, `output_tokens`, and `cache_creation_input_tokens`.
- Large valid usage fields are now counted normally, including million- and billion-scale values.
- The accounting layer now pauses only for malformed token usage, cursor uncertainty, explicit token budgets, turn caps, wall-clock caps, or hook failures.
- Malformed usage now records `invalid_usage_field` instead of the misleading `cap_exceeded` event.
- Goals already stuck by the old false-positive `cap_exceeded` event auto-recover on the next Stop or SessionStart hook when there is no `/compact` cursor uncertainty.

## Migration notes

- No SQLite schema change from v0.2.4.
- Existing valid goals paused by the old per-message usage cap can resume automatically after the plugin is reloaded.

## Verified locally

- `npm --prefix mcp/goal-server test` - 91 passed
- `npm --prefix mcp/goal-server run build`
- `bats $(find tests -name '*.bats' | sort)` - 146 passed
- `npm --prefix docs run build`
- `git diff --check`
- `claude plugin validate .`
- Release tarball SHA-256: `c53a3918d30eda2dab1ef9d2f9a008dcce4950cf352f5a1df2860ec072b0f68f`

---

# claude-goal v0.2.4

**Natural-language goal starts.**

This release closes the UX gap with Codex-style goals: users can explicitly ask Claude to set up a goal without typing the `/goal-start` slash command.

## What's new

- Explicit prose such as "set up a goal and continue", "make this a goal", or "start a claude-goal for this" now routes through the same persisted `create_goal` path as `/goal-start`.
- Natural-language goal starts default to `budget_profile="auto"` when no budget is specified, so Claude can set up the run envelope without making users type raw token counts.
- Slash-command compatibility is preserved: `/goal-start "objective"` with no `--budget` remains unbounded.
- Users can still request `quick`, `standard`, `deep`, `overnight`, `auto`, raw token budgets, or unbounded mode explicitly.
- The MCP `create_goal` metadata now mirrors Codex's guardrail: call it only for explicit goal requests, never by silently inferring a goal from ordinary tasks.

## Docs and tests

- README and docs now explain both startup paths, the prose `auto` default, and the unbounded slash default.
- Added regression tests for the goal-start skill trigger text, MCP tool metadata, and UserPromptExpansion's ordinary-prose no-op boundary.

## Migration notes

- No SQLite schema change from v0.2.3.
- Existing goals and installed databases continue unchanged.

## Verified locally

- `npm --prefix mcp/goal-server test` - 89 passed
- `npm --prefix mcp/goal-server run build`
- `bats $(find tests -name '*.bats' | sort)` - 143 passed
- `npm --prefix docs run build`
- `git diff --check`
- Release tarball SHA-256: `54fc8ce1f4c7722afacc6ec0fc8b5ef24aef4773efd508ffd9ce213cf663a124`

---

# claude-goal v0.2.3

**Evaluator-completion fix for accounting-error pauses.**

This patch fixes the lifecycle edge case where a goal could finish successfully, have the evaluator verify it, then remain stuck in `paused (accounting_error)` because `update_goal status:complete` only accepted `active` goals.

## Fixed

- `update_goal status:complete completed_by:"evaluator"` can now close a goal paused with `paused_reason='accounting_error'`.
- Completion clears stale `paused_reason` and `accounting_uncertain` state so `/goal-status` and `/goal-history` do not keep reporting a resolved accounting warning.
- Ordinary `completed_by:"self_update"` completion still cannot bypass an accounting-error pause, and `budget_limited` goals still require `/goal-extend --add-tokens`.

## Migration notes

- No SQLite schema change from v0.2.2.
- Existing stuck goals can be completed after updating/reloading the plugin if the evaluator has already verified completion.

## Verified locally

- `npm --prefix mcp/goal-server test` - 87 passed
- `npm --prefix mcp/goal-server run build`
- `bats $(find tests -name '*.bats' | sort)` - 140 passed
- `npm --prefix docs run build`
- `git diff --check`
- Release tarball SHA-256: `8fe7fedcd52012e10d1ced36f0cfc456664c6082142788c995486a084949a7d3`

---

# claude-goal v0.2.2

**Marketplace-install packaging fix.**

This patch exists because Claude Code marketplace plugin sources clone git repositories directly. The v0.2.1 source commit was valid for development and tarball releases, but marketplace installs cloned it without the built MCP `dist/` directory or bundled runtime dependencies, so the `goal` MCP server did not connect after `/reload-plugins`.

## Fixed

- Published an installable marketplace artifact branch that contains the built MCP server and pruned runtime dependencies.
- Bumped the plugin version to `0.2.2` so users with the broken marketplace-installed `0.2.1` cache can receive the fixed artifact through `/plugin update`.
- No goal runtime behavior or SQLite schema changes from v0.2.1.

## Verified locally

- `npm --prefix mcp/goal-server test`
- `npm --prefix mcp/goal-server run build`
- `bats $(find tests -name '*.bats' | sort)`
- `npm --prefix docs run build`
- `claude plugin validate` against the marketplace artifact clone
- Marketplace artifact clone smoke-loaded the built MCP modules

---

# claude-goal v0.2.1

**Runtime hardening for smart budget goal creation.**

This patch release keeps the v0.2.0 budget-profile feature set unchanged and tightens malformed-input handling around `create_goal`.

## Fixed

- MCP `create_goal` now validates `session_id`, `objective`, and `token_budget` at runtime before calling the repository layer.
- Raw token budgets must be positive integers, so malformed clients cannot pass string, zero, negative, or fractional token budgets into SQLite-backed goal state.
- Non-string objectives now return a structured `objective is required` error instead of risking a thrown `.trim()` call.
- `GoalsRepo.create` now independently rejects blank session IDs, whitespace-only objectives, invalid budget profiles, and malformed raw token budgets before writing.

## Migration notes

- No schema change from v0.2.0. Existing v4 databases continue to work unchanged.
- Budget profiles, `auto`, raw token budgets, status/history profile display, and `--add-tokens` behavior are unchanged.

## Verified locally

- `npm --prefix mcp/goal-server test` - 83 passed
- `npm --prefix mcp/goal-server run build`
- `bats $(find tests -name '*.bats' | sort)` - 140 passed
- `npm --prefix docs run build`
- `git diff --check`

---

# claude-goal v0.2.0

**Smart budget profiles for smoother `/goal-start` UX.**

This release makes budgeted goals human-friendly: users can now write profile names instead of raw token counts.

## What's new

- `/goal-start "objective"` still starts an unbounded token-budget goal by default.
- `/goal-start "objective" --budget quick|standard|deep|overnight|auto` now selects a full run envelope.
- Profiles set token budget, continuation cap, and wall-clock cap together:
  - `quick`: 500K tokens, 25 continuations, 1 hour
  - `standard`: 2M tokens, 75 continuations, 4 hours
  - `deep`: 5M tokens, 150 continuations, 8 hours
  - `overnight`: 20M tokens, 500 continuations, 12 hours
- `auto` deterministically selects a profile from the objective text:
  - explicit overnight/weekend wording -> `overnight`
  - migrations, repo-wide refactors, redesigns, integrations, multi-module changes, or many named files -> `deep`
  - bounded features, bug fixes with tests, or medium refactors -> `standard`
  - narrow inspection-style work -> `quick`
- Raw numeric budgets remain supported as an advanced path and are mutually exclusive with `budget_profile`.
- `/goal-status` and `/goal-history` now show the selected profile and whether it was explicit, auto-selected, raw tokens, or unbounded.

## Migration notes

- SQLite schema moves to v4 and adds `goals.budget_profile` plus `goals.budget_source`.
- Existing budgeted goals migrate as `budget_source='tokens'`; unbudgeted goals migrate as `budget_source='none'`.
- `/goal-doctor` now checks for schema version 4.
- `--add-tokens` on an unbudgeted active goal now marks the goal as raw-token sourced so status/history stay coherent.

## Reliability

- F5 final-turn token accounting now records the `final_turn_accounted` audit event from the final observed row state, making the completion-token audit trail more reliable when transcripts flush late.

## Docs and tests

- README and docs now lead with profile names and move raw token sizing to advanced sections.
- Verified locally:
  - `npm --prefix mcp/goal-server test` — 78 passed
  - `npm --prefix mcp/goal-server run build`
  - `bats $(find tests -name '*.bats' | sort)` — 140 passed
  - `npm --prefix docs run build`
  - `git diff --check`

---

# claude-goal v0.1.1

**Maintenance patch — no functional changes.**

- CI: bats job now installs Node + runs `npm ci` so `release-tarball.bats` (which invokes `scripts/build-tarball.sh`) passes on Ubuntu runners
- Repo hygiene: removed internal dev artifacts that shouldn't ship publicly (Phase 0 probe data, phase smoke reports, audit handoffs, design spec + implementation plan, captured-transcript fixtures with user-specific paths)
- Tarball: now ships `ROADMAP.md` and excludes the deleted `docs/` tree
- `.gitignore`: extended to keep the above patterns and local `.claude/` settings out of the repo
- Identity: the repo's git history was rewritten in this release to attribute every commit to `Nuko Nova Dynamics <hello@nukonova.com>`; v0.1.0's tag and release were re-cut from the rewritten history with a smaller, cleaner tarball

The plugin's runtime behavior, command surface, and on-disk schema are byte-identical to v0.1.0. Existing v0.1.0 installs do not need to upgrade for any functional reason; this release only cleans up what ships in the public repo and tarball.

---

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

### From the Nuko Nova Tools marketplace (recommended)

```
/plugin marketplace add nuko-nova-dynamics/claude-marketplace
/plugin install claude-goal@nuko-nova-tools
```

Updates via `/plugin update claude-goal` once new versions are tagged.

### From the release tarball (offline / air-gapped)

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
