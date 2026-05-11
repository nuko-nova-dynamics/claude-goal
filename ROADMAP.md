# claude-goal Roadmap

This document tracks the planned evolution of the plugin beyond v0.1.0.

v0.1.0 is the **production-grade goal-management** layer that complements Claude Code's built-in `/goal` (shipped in CC 2.1.139). Where the built-in is a session-scoped Stop hook plus a Haiku evaluator, this plugin adds deterministic budgets, lifecycle commands (pause/resume/extend/abandon), `/compact` recovery, and SQLite persistence.

## v0.2 — headline features

### 1. Haiku evaluator (the big one)

**Status:** designed, not implemented
**Inspired by:** Claude Code's native `/goal` mechanism — a separate small/fast model judges the completion condition each turn instead of the working model self-auditing.

**Why:** A model that has just spent N turns working toward an objective is the *worst* judge of whether it's done — confirmation bias, sunk-cost, "almost there"-ism. Anthropic's design routes completion judgment to a fresh-context Haiku evaluator, which gets the objective + recent transcript and returns yes/no + a short reason. That's strictly better than our current `update_goal` self-audit pattern.

**What changes:**

- New MCP tool: `evaluate_completion(session_id, objective, recent_transcript)` returning `{ done: bool, reason: string }`.
- Stop hook calls `evaluate_completion` after accounting catchup, before deciding to inject a continuation. If `done`, transition to `complete` and stay silent. Else inject continuation with the evaluator's reason appended as guidance.
- Backwards-compatible: keep the `update_goal status=complete` path so the working model can still self-signal completion. The evaluator is a parallel path that decides done EITHER WAY.
- Configuration: `--evaluator haiku|self|both` flag on `/goal-start`. Default `both`: either the model self-signals OR the evaluator says done.

**Cost:** one Haiku call per turn (~few hundred tokens of evaluator input + a one-line yes/no output). Negligible against the main-turn cost. Anthropic explicitly notes the same: *"Evaluation tokens are billed on the small fast model configured for your provider and are typically negligible compared to main-turn spend."*

**Open questions:**

- How does the plugin authenticate to the Anthropic API for the Haiku call? CC has the user's session credentials but doesn't expose them to plugins. Options: (a) require `ANTHROPIC_API_KEY` env var, (b) use the MCP server's stdio relationship to Claude Code to delegate (probably impossible without CC support), (c) make the evaluator pluggable so users can point at any LLM.
- Reason-text accumulation: if the evaluator says "no" 50 times, do we surface the reason chain in `/goal-status` for visibility? Probably yes.

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
