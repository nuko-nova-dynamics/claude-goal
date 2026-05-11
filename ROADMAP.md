# claude-goal Roadmap

This document tracks the planned evolution of the plugin beyond v0.1.0.

v0.1.0 is the **production-grade goal-management** layer that complements Claude Code's built-in `/goal` (shipped in CC 2.1.139). Where the built-in is a session-scoped Stop hook plus a Haiku evaluator, this plugin adds deterministic budgets, lifecycle commands (pause/resume/extend/abandon), `/compact` recovery, and SQLite persistence.

## v0.2 — headline features

### 1. Pluggable evaluator boundary (the big one)

**Status:** designed, not implemented
**Inspired by:** Claude Code's native `/goal` mechanism, with a Codex-flagged architectural correction.

**The real insight** (per Codex, the original `/goal` implementer in `codex-rs`): the win isn't the Haiku model specifically — it's **separating the completion condition from the worker's self-narrative**. A model that has spent N turns working toward an objective has sunk-cost bias to declare done. ANY separate evaluator without that context bias — Haiku, GPT-4o-mini, a local model, or even another instance of the same Claude — beats same-model self-audit. So the v0.2 design is a **pluggable evaluator boundary**, not a Haiku integration.

**What changes:**

- New MCP tool: `evaluate_completion(session_id, objective, recent_transcript)` returning `{ done: bool, reason: string }`. Implementation calls whatever evaluator the user configured.
- Configuration: `evaluator.provider` setting in `.claude-plugin/plugin.json` or per-goal flag `--evaluator <name>`. Built-in providers: `anthropic-haiku` (requires `ANTHROPIC_API_KEY`), `openai-mini` (requires `OPENAI_API_KEY`), `local-ollama` (HTTP), `none` (skip eval, model self-audit only — current behavior, default for v0.2).
- Stop hook calls `evaluate_completion` after accounting catchup, before injecting a continuation. If `done`, transition to `complete`. Else inject continuation with the evaluator's reason appended as guidance.
- Backwards-compatible: `update_goal status=complete` self-audit path still works. The evaluator is parallel.
- **Distinct event types when evaluator wins vs self-signal wins** (per Codex's warning): `goal_completed_by_evaluator` carries the evaluator's reason in payload_json; `goal_completed_by_self_update` is the existing path. Audit-trail-distinguishable.
- **`--evaluator both` mode safety:** when both paths are active, evaluator-driven completion requires reason text PLUS the audit event before transitioning. Prevents "either side prematurely stops without trace".

**Evaluator must be conservative** (Codex's warning from `codex-rs` experience): the failure mode is "declares done because progress *sounds* complete" — e.g., the transcript contains "successfully ran tests" but some failed. The evaluator prompt template biases toward "not done" — requires explicit evidence in the transcript, not optimistic language.

**Prerequisite: F5 must land first.** If the evaluator can trigger completion, every evaluator-driven win currently skips the final-turn accounting pass (same root cause as F5). F5 fix gates v0.2 evaluator rollout.

**Cost:** one evaluator call per turn (~few hundred tokens input + one-line output). Negligible against main-turn cost. With `provider: none` (default), zero added cost.

### 2. `-p` and Remote Control mode support

Anthropic's native `/goal` works in `claude -p` (one-shot) and Remote Control. Our hooks fire in interactive mode but we've never validated the headless / API-driven paths. v0.2 includes one Codex smoke per mode.

### 3. F5 — final-turn tokens at completion

The known undercount where the completion turn's own token cost is never accounted (because Stop hook accounting runs at the START of the hook, before `update_goal` detection, and no further hook fires after `complete`). Fix: run a second accounting pass between `update_goal` detection and the silent-stop exit.

### 4. Per-subagent token attribution

Today, subagent tool calls fire `PostToolBatch` on the parent session, so subagent activity rolls into the parent's `tokens_used`. v0.2: extract `agent_id` / `parent_agent_id` from the hook payload (CC 2.1.139 added these as `x-claude-code-agent-id` / `x-claude-code-parent-agent-id` headers per the release notes) and split accounting into a `subagent_tokens` column.

### 5. `/goal-history` command

List past goals for the current session (complete / abandoned / orphaned) with duration, tokens spent, and outcome. Backed by the existing `goals` table — just a new read path.

## v0.3 and beyond — speculative

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
| v0.1.0 | TBD (pending audit + soak) | Initial public beta — goal lifecycle commands, budgets, `/compact` recovery, SQLite persistence |
| v0.1.x | rolling | Bugfixes from outside-user feedback |
| v0.2.0 | tentative Q3 2026 | Haiku evaluator, `-p` / Remote Control, F5 fix, per-subagent attribution |
| v0.3.0 | speculative | Multi-objective, cost preview, web overlay |
