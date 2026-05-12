# claude-goal Roadmap

This document captures what shipped in v0.1.0 and what's planned for later versions.

v0.1.0 is the **production-grade goal-management** layer that complements Claude Code's built-in `/goal` (shipped in CC 2.1.139). Where the built-in is a session-scoped Stop hook plus a Haiku evaluator, this plugin adds deterministic budgets, lifecycle commands (pause/resume/extend/abandon), `/compact` recovery, SQLite persistence, a plugin subagent evaluator that verifies with tools, and F5 final-turn token accounting.

## v0.1.0 — landed features

### 1. Completion evaluator (implemented)

**Status:** SHIPPED in `agents/goal-evaluator.md`.
**Inspired by:** Claude Code's native `/goal` mechanism, with a Codex-flagged architectural correction.

**The insight** (per Codex, the original `/goal` implementer in `codex-rs`): the win isn't the Haiku model specifically — it's **separating the completion condition from the worker's self-narrative**. A model that has spent N turns working toward an objective has sunk-cost bias to declare done. ANY separate evaluator without that context bias — Haiku, GPT-4o-mini, a local model, or even another instance of the same Claude — beats same-model self-audit.

**What shipped: plugin subagent evaluator** in `agents/goal-evaluator.md`. Why a subagent and not a prompt-hook:

The original plan was a prompt-type Stop hook (mirroring Anthropic's native `/goal` mechanism). But reading the Claude Code hooks spec revealed that prompt hooks receive only the fixed input JSON (`session_id`, `transcript_path`, `last_assistant_message`, etc.) and CANNOT read files or call tools. Our active goal's objective lives in our SQLite DB, NOT in CC's hook input. A prompt-hook evaluator literally cannot see what the user asked for.

An explicitly dispatched subagent is the right transport: it gives the worker an independent verifier with tool access while avoiding Claude Code's experimental `type:"agent"` hook runtime. The subagent gets:
- A fresh context window, no inherited conversation (no sunk-cost bias)
- Bash + Read + jq + sqlite3 access when the worker session can use those tools — can query our DB for the objective, read the transcript, AND verify with tools (run the test, read the file, check the exit code)
- Returns `{"verdict":"complete"|"incomplete"|"unverifiable","reason":"..."}`

Phase 1c rejected the experimental `type:"agent"` Stop hook for v0.1.0: Claude Code 2.1.139 exposes no hook-local permission grant field, plugin-shipped settings do not grant Bash/Read to hooks, and real runs showed the hook failing to return structured output after tool use.

Implementation:
- `hooks/hooks.json` keeps only the deterministic Stop command hook (`scripts/stop.sh`).
- `prompts/continuation.md` and `skills/goal-start/SKILL.md` instruct the worker to dispatch `claude-goal:goal-evaluator` before completion.
- The evaluator subagent returns JSON verdicts and does not call `update_goal` itself.
- When the evaluator returns `complete`, the worker calls our MCP `update_goal` tool with `completed_by: "evaluator"`. The MCP tool records a `goal_completed_by_evaluator` event distinct from `goal_completed_by_self_update`. Audit-distinguishable.
- The two completion paths coexist: worker can self-signal via `update_goal status:complete` (fallback behavior, `goal_completed_by_self_update`), OR the worker can complete after evaluator confirmation (`goal_completed_by_evaluator`).

**Evaluator prompt is conservative by design** (Codex's warning from `codex-rs` experience): the failure mode is "declares done because progress *sounds* complete." The prompt explicitly says: optimistic language is never proof; require explicit evidence (exit codes, file contents, test reports). Vague "should work now" → return incomplete.

### 2. F5 — final-turn tokens at completion (SHIPPED)

**Status:** SHIPPED in `scripts/stop.sh` (commit 8a2b90e).

The completion turn's tokens are now captured by a bounded retry loop after `detect_update_goal` returns true, and also when `update_goal` has already transitioned the row to `complete` before Stop reads the final transcript bytes. Five retries at 100ms intervals re-run `account_advance_inline` to catch transcripts that flush after the start-of-hook accounting pass. Records a `final_turn_accounted` event when the retry advances the byte offset.

## v0.1.0 — phase 2 in progress

These are also v0.1.0 work, queued behind the audit on phase 1.

### 3. Per-subagent token attribution

Claude Code stores subagent assistant usage in nested `subagents/agent-*.jsonl` transcripts. Phase 2 reads `agent_id` from `PostToolBatch`, accounts those nested transcripts with per-agent cursors, and rolls the total into `goals.subagent_tokens` while keeping parent-worker usage in `tokens_used`.

### 4. `/goal-history` command

List past goals for the current session (complete / abandoned / orphaned) with duration, tokens spent, and outcome. Backed by the existing `goals` table — just a new read path.

### 5. `-p` and Remote Control mode validation

Anthropic's native `/goal` works in `claude -p` (one-shot) and Remote Control. Our hooks fire in interactive mode but we've never validated the headless / API-driven paths. Phase 2 includes a Codex smoke per mode.

## v0.2+ — speculative

- **Multi-objective goals** with per-objective progress tracking: `/goal-start "A=tests pass; B=lint clean; C=doc updated"` then completion needs all three.
- **Cost preview**: before `/goal-start`, run a tiny Haiku prompt over the objective to estimate "this will likely cost ~N tokens", warn if `--budget` is way under.
- **Cross-session goal chains**: explicit "this goal depends on goal X having completed" — for orchestrated multi-stage work.
- **Web UI / overlay**: a separate process that watches the SQLite DB and renders live status in a browser tab. Useful when running `claude` over SSH.
- **Plugin-level marketplace publish** once Anthropic ships the marketplace scope in CC.

## Non-goals

- Replacing Anthropic's built-in `/goal`. The two are complementary; the plugin's value is the lifecycle + persistence + budget primitives, not the autonomous loop itself.
- Supporting Windows native (cmd.exe / Git Bash without a proper bash layer). The fail-fast guard in `stop.sh` stays. WSL is best-effort.
- Becoming a general agent framework. The plugin is specifically about *goal-bounded autonomous turns*. Workflows, scheduled jobs, and multi-agent orchestration belong in other tools (`/loop` for time-driven, agent frameworks for orchestration).

## Status tracking

| Tag | Date | Headline |
|---|---|---|
| v0.1.0 | TBD (pending audits + soak) | Initial public beta — goal lifecycle commands, budgets, `/compact` recovery, SQLite persistence, F5 final-turn accounting, evaluator subagent, per-subagent token attribution, `/goal-history`, `-p`/Remote Control validated |
| v0.1.x | rolling | Bugfixes from outside-user feedback |
| v0.2.0 | speculative | Multi-objective goals, cost preview, web overlay, marketplace publish |
