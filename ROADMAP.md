# claude-goal Roadmap

This document tracks the planned evolution of the plugin beyond v0.1.0.

v0.1.0 is the **production-grade goal-management** layer that complements Claude Code's built-in `/goal` (shipped in CC 2.1.139). Where the built-in is a session-scoped Stop hook plus a Haiku evaluator, this plugin adds deterministic budgets, lifecycle commands (pause/resume/extend/abandon), `/compact` recovery, and SQLite persistence.

## v0.2 — headline features

### 1. Pluggable evaluator boundary (the big one)

**Status:** designed, not implemented
**Inspired by:** Claude Code's native `/goal` mechanism, with a Codex-flagged architectural correction.

**The real insight** (per Codex, the original `/goal` implementer in `codex-rs`): the win isn't the Haiku model specifically — it's **separating the completion condition from the worker's self-narrative**. A model that has spent N turns working toward an objective has sunk-cost bias to declare done. ANY separate evaluator without that context bias — Haiku, GPT-4o-mini, a local model, or even another instance of the same Claude — beats same-model self-audit. So the v0.2 design is a **pluggable evaluator boundary**, not a Haiku integration.

**Two transport options for the evaluator boundary** — both achieve the same architectural decoupling, with different trade-offs. v0.2 supports both, default is subagent (no auth setup needed).

### Transport A: subagent dispatch (default)

The Stop hook injects a continuation prompt instructing the working model to dispatch a `goal-evaluator` subagent before continuing. The subagent gets:
- A fresh context window (no inherited conversation)
- The objective text
- File access (so it can actually run tests, grep files, verify state)
- Instructions to return yes/no + reason

The subagent's verdict drives the next turn: "yes" → call `update_goal complete`; "no" → keep working with the reason as guidance.

**Why this is stronger than Anthropic's design**: Anthropic's Haiku evaluator explicitly cannot call tools — it judges only from transcript text. A subagent evaluator can actually verify with tools (`npm test`, `grep`, `git status`). For objectives whose completion depends on observable state, a tool-using evaluator catches misleading "successfully ran tests" transcript lines that the test output contradicts.

**Cost:** full subagent context boot per turn (CLAUDE.md + system prompt + evaluator instructions, ~tens of thousands of tokens). More expensive than Haiku-API but inside the same authenticated session — no key management.

**Auth:** zero. Uses the user's existing CC session, whatever provider it's on (Anthropic API, Bedrock, Vertex).

### Transport B: external small-fast-model API

For users who want lower per-turn cost and don't need tool-using verification, a Haiku/GPT-4o-mini/local-LLM call works the same way as Anthropic's native `/goal` design — fresh context, transcript-only judgment, very cheap per turn.

- New MCP tool: `evaluate_completion(session_id, objective, recent_transcript)` returning `{ done: bool, reason: string }`.
- Configuration: `evaluator.provider` setting in `.claude-plugin/plugin.json` or per-goal flag `--evaluator <name>`. Providers: `anthropic-haiku`, `anthropic-opus`, `anthropic-sonnet`, `openai-mini`, `local-ollama`, `none`.
- Requires the provider's API key in env.

### Shared design (both transports)

- Stop hook routes through the evaluator after accounting catchup, before continuation injection.
- Backwards-compatible: `update_goal status=complete` self-audit path still works as a parallel signal.
- **Distinct event types when evaluator wins vs self-signal wins**: `goal_completed_by_evaluator` carries the verdict + reason in `payload_json`; `goal_completed_by_self_update` is the existing path. Audit-distinguishable.
- **`--evaluator both` mode safety**: evaluator-driven completion requires reason text PLUS the audit event before transitioning. Prevents either side prematurely stopping without trace.

**Evaluator must be conservative** (Codex's warning from `codex-rs` experience): the failure mode is "declares done because progress *sounds* complete" — e.g., transcript contains "successfully ran tests" but some failed. Both transports' evaluator prompts bias toward "not done" — require explicit evidence (file contents, exit codes, test reports), not optimistic language. Subagent transport has the upper hand here because it can verify with tools instead of trusting the transcript.

**Prerequisite: F5 must land first.** If the evaluator can trigger completion, every evaluator-driven win currently skips the final-turn accounting pass. F5 fix gates v0.2 evaluator rollout.

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
