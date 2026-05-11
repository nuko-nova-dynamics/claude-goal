# claude-goal Roadmap

This document tracks the planned evolution of the plugin beyond v0.1.0.

v0.1.0 is the **production-grade goal-management** layer that complements Claude Code's built-in `/goal` (shipped in CC 2.1.139). Where the built-in is a session-scoped Stop hook plus a Haiku evaluator, this plugin adds deterministic budgets, lifecycle commands (pause/resume/extend/abandon), `/compact` recovery, and SQLite persistence.

## v0.2 — headline features

### 1. Pluggable evaluator boundary (the big one)

**Status:** designed, not implemented
**Inspired by:** Claude Code's native `/goal` mechanism, with a Codex-flagged architectural correction.

**The real insight** (per Codex, the original `/goal` implementer in `codex-rs`): the win isn't the Haiku model specifically — it's **separating the completion condition from the worker's self-narrative**. A model that has spent N turns working toward an objective has sunk-cost bias to declare done. ANY separate evaluator without that context bias — Haiku, GPT-4o-mini, a local model, or even another instance of the same Claude — beats same-model self-audit. So the v0.2 design is a **pluggable evaluator boundary**, not a Haiku integration.

**Three transport options for the evaluator boundary** — all achieve the architectural decoupling (fresh context, no sunk-cost bias). v0.2 supports all three, default is the prompt-hook transport (mirrors Anthropic's own design, zero auth setup).

### Transport A: prompt hook (default) — mirrors native `/goal`

Claude Code's hooks system has two hook types: **prompt hooks** (make a model call using the session's "small fast model" and return text) and **agent hooks** (spawn a subagent). These are documented as separate first-class mechanisms at https://code.claude.com/docs/en/hooks. Anthropic's native `/goal` is explicitly a prompt hook (*"`/goal` is a wrapper around a session-scoped prompt-based Stop hook"* per https://code.claude.com/docs/en/goal). Plugins can ship prompt hooks too.

**For our plugin:** add a prompt-type Stop hook in `hooks/hooks.json` whose body is the evaluator prompt template ("Given this objective and the last 3 turns of conversation, is the objective complete? Be conservative — require explicit evidence, not optimistic language. Return `done: true|false, reason: <short>`."). The hook runs after the current `scripts/stop.sh` completes accounting; if `done`, the Stop hook chain transitions to `complete`; if not, continuation injection fires as today with the evaluator's reason appended as guidance.

- **Auth:** session credentials — OAuth (most users) or API key, whatever is already configured. Zero setup for the plugin user.
- **Cost:** the model call only (~few hundred tokens of evaluator input + a one-line output). Negligible vs main-turn spend, same as Anthropic explicitly states for their evaluator.
- **Model choice:** controlled by Claude Code's `ANTHROPIC_DEFAULT_HAIKU_MODEL` env var or the hook's optional `model: <alias>` field. Defaults to a fast model (Haiku family); users can override to any model alias including Opus.
- **Limitation:** transcript-only judgment, no tool use. Same as Anthropic's `/goal`.

### Transport B: agent hook / subagent dispatch — for tool-using verification

When the objective's completion depends on observable state that a transcript can lie about (e.g., "tests pass" but the transcript only contains an optimistic "successfully ran tests" line), use a subagent evaluator instead. Defined via an `agent` hook in `hooks/hooks.json`, the subagent gets:
- Fresh context window, no inherited conversation
- File access — can actually run `npm test`, grep, verify state
- Returns the same yes/no + reason

**Strictly stronger than Transport A** for state-dependent objectives — the subagent verifies rather than infers. But pricier per turn (full subagent context boot ~tens of thousands of tokens vs the prompt hook's few hundred).

- **Auth:** session credentials — same as Transport A.
- **Cost:** subagent boot per turn. Higher than prompt hook, much lower than running the main agent again.
- **Opt-in flag:** `--evaluator subagent` on `/goal-start`.

### Transport C: external small-fast-model API — for explicit provider control

For users who want a specific provider distinct from their CC session (e.g., they're on Bedrock for the main session but want to route the evaluator to Anthropic API direct), or want to use OpenAI/local models as the evaluator.

- New MCP tool: `evaluate_completion(session_id, objective, recent_transcript)` returning `{ done: bool, reason: string }`. Implementation calls the configured provider.
- Configuration: `evaluator.provider` in `.claude-plugin/plugin.json` or `--evaluator <name>` flag. Providers: `anthropic-haiku`, `openai-mini`, `local-ollama`.
- **Auth:** requires the corresponding API key in env. Only path that needs key management.
- **Use case:** narrow — users who specifically want a different provider from their session.

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
