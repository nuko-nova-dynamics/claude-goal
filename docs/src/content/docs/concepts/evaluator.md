---
title: Completion evaluator
description: Why a tool-equipped subagent beats same-model self-audit — and how the dual-path completion design works.
sidebar:
  order: 3
---

The most important design decision in `claude-goal` is **how to decide a goal is done**.

A model that has spent N turns working toward an objective has sunk-cost bias to declare done. Optimistic transcript language — "I've now refactored the module, all tests should pass" — is the failure mode. If you trust the worker to self-audit, you ship false positives.

This page explains the two-path completion design and why it works.

## The insight

> The win isn't the Haiku model specifically — it's separating the completion condition from the worker's self-narrative.

This is Codex's experience from `codex-rs`, where the original `/goal` was built. Any separate evaluator without that context bias — Haiku, GPT-4o-mini, a local model, or even another instance of the same Claude — beats same-model self-audit. The mechanism matters more than the model choice.

## Why a subagent, not a hook

The original design was a `type: "prompt"` Stop hook (mirroring Anthropic's native `/goal` mechanism in CC 2.1.139+). But reading the Claude Code hooks spec revealed a fatal constraint: prompt hooks receive only the fixed input JSON (`session_id`, `transcript_path`, `last_assistant_message`, etc.) and **cannot read files or call tools**.

The active goal's objective lives in our SQLite DB, not in CC's hook input. A prompt-hook evaluator literally cannot see what the user asked for.

A plugin subagent solves this:

| | Prompt hook | Plugin subagent |
|---|---|---|
| Fresh context, no sunk-cost bias | ✓ | ✓ |
| Can read transcript | ✓ | ✓ |
| Can read the DB for the objective | ✗ | ✓ |
| Can run tools to verify | ✗ | ✓ |
| Returns structured verdict | text only | JSON |

The evaluator subagent is dispatched by the worker, not by a hook. The continuation prompt instructs the worker:

> Before marking the goal complete, dispatch the `claude-goal:goal-evaluator` subagent. Pass the objective and your evidence. Wait for its verdict.

## What the evaluator does

The subagent (defined in `agents/goal-evaluator.md`) runs in a fresh context with `Bash + Read + jq + sqlite3`. Each invocation:

1. Reads the active goal's objective from `goals.db`
2. Inspects recent transcript messages for what the worker claims to have done
3. **Verifies with tools** — runs the test, reads the file, checks the exit code, queries the API
4. Returns `{"verdict": "complete" | "incomplete" | "unverifiable", "reason": "<concrete evidence or what's missing>"}`

The verdict drives the worker's next action:

- `complete` → call `update_goal status:complete completed_by:"evaluator"`
- `incomplete` → continue working on the gap the evaluator identified
- `unverifiable` → the evaluator can't tell; the worker falls back to self-audit

## Conservative by design

The evaluator prompt explicitly forbids optimistic reasoning:

> Optimistic language is never proof. "Should work" is not "works." Require concrete evidence: a passing test, a file's actual contents, an exit code, a specific log line.
>
> Vague claims → return `incomplete`.

This makes false positives rare. False negatives (a goal is actually done but the evaluator can't find the evidence) fall through to `unverifiable`, and the worker's self-audit path serves as the safety net.

## The two paths coexist

| Path | Trigger | Event logged |
|---|---|---|
| Evaluator | Worker dispatches subagent, gets `complete`, calls `update_goal completed_by:"evaluator"` | `goal_completed_by_evaluator` |
| Self-audit | Worker calls `update_goal status:complete` directly | `goal_completed_by_self_update` |

Both are valid completion. The distinct events let you post-hoc audit which mechanism you're actually relying on. In practice, a healthy goal completes via the evaluator path; self-audit fires when the evaluator is unavailable or returns `unverifiable`.

## Why not Haiku?

Anthropic's native `/goal` (CC 2.1.139+) uses a fresh Haiku call per turn as the evaluator. That works for casual conditions ("keep working until the lint passes") because Haiku can read the transcript and decide.

But Haiku-as-hook has the same constraint as a prompt hook — it can't read files or run tools. For an objective like "the production build succeeds with no errors," Haiku has to **infer** from transcript language. That's exactly the failure mode the subagent design avoids.

If you want Haiku in the loop for casual goals, **use the native `/goal`**. The two commands coexist. Use `/goal-start` from this plugin when you need tool-verified completion.

## What the evaluator cannot do

The evaluator's tool surface is bounded:

- **No `Write` / `Edit`** — it cannot modify the codebase. Its job is to verify, not to fix.
- **No `Task` dispatch** — it cannot launch further subagents.
- **No `update_goal`** — it returns a verdict only. The worker calls `update_goal` based on the verdict.

This separation keeps the evaluator's role pure: read, run, judge. It also makes its output auditable — every completion attributed to the evaluator has a verdict reason logged.
