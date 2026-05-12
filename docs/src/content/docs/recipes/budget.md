---
title: Run a goal under budget
description: A worked example of an hour-long autonomous refactor with a multi-million-token budget, watching it pause, and resuming with extra turns.
sidebar:
  order: 1
---

This recipe walks through what a **real** autonomous goal looks like: hours of wall-clock time, hundreds of turns, millions of tokens.

## The scenario

You want Claude to refactor an authentication module to use async/await. Multiple files, contract preservation, tests must pass. You expect this to take **1–3 hours of model time** if it works end-to-end.

## Set the budget for the shape of the work

```
/goal-start "refactor src/auth/* to use async/await; preserve existing test contracts; ensure all tests in test/auth/ pass" --budget 3000000
```

Notes on the objective and the budget:

- **Concrete scope** — `src/auth/*`, not "the auth code"
- **Explicit acceptance criterion** — tests pass in `test/auth/`
- **Constraint** — preserve existing contracts (a hint to the evaluator: contract-breaking refactors → `incomplete`)
- **Budget at 3M tokens** — a multi-file refactor with verification will burn 1–2M comfortably; 3M leaves headroom so we don't trip on the first iteration

## What the loop looks like at minute 15

```
/goal-status

◎ Goal: refactor src/auth/* to use async/await...
  status:      active
  tokens:      612,043 worker · 84,200 subagent (696,243 / 3,000,000)
  continuations remaining: 32 / 50
  wall-clock used: 0h 15m / 4h
```

Worker has read several files, made initial changes, and the evaluator has dispatched once to check progress (subagent tokens are non-zero). The cache has warmed — subsequent turns are cheap.

## At minute 45 — first continuation cap

50 continuation turns is the default. For a real refactor you'll burn through them before completion:

```
/goal-status

◎ Goal: refactor src/auth/* to use async/await...
  status:      paused
  paused_reason: continuation_cap
  tokens:      1,401,328 worker · 211,400 subagent (1,612,728 / 3,000,000)
  continuations remaining: 0 / 50
  wall-clock used: 0h 47m / 4h
```

The token budget is fine — you've used about half. The turn cap fired. Extend it:

```
/goal-extend --add-continuations 100
```

Now the goal resumes with 100 more turns. For long refactors, expect to extend two or three times.

## The evaluator fires

The continuation prompt has been telling the worker, on every turn, to dispatch the evaluator before declaring done. When it thinks it's done:

```
[Task] dispatching claude-goal:goal-evaluator with objective + evidence...
```

The evaluator subagent reads the active goal, inspects recent assistant turns, then **runs the tests** (Bash tool). Verdict:

```json
{
  "verdict": "incomplete",
  "reason": "test/auth/session.test.ts:42 fails — expected resolved promise, got rejection from missing `await` in src/auth/session.ts:87. Worker reported tests passing but `npm test test/auth` shows 1/13 failing."
}
```

Notice: the evaluator caught a false positive. The worker claimed done; the evaluator ran the tests and found a missing `await`. This is exactly the failure mode the dual-path design protects against.

The worker reads the `incomplete` verdict, addresses the gap, and the loop continues.

## Eventual completion

After another 40 turns and 1.1M more tokens:

```
{
  "verdict": "complete",
  "reason": "All 13 tests in test/auth/ pass via `npm test test/auth`. Async/await replaces .then() chains in src/auth/oauth.ts:23, src/auth/session.ts:41+87, src/auth/tokens.ts:18. No public API signatures changed."
}
```

The worker calls `update_goal status:complete completed_by:"evaluator"` and stops.

Final status:

```
/goal-status

◎ Goal: refactor src/auth/* to use async/await...
  status:      complete
  completed_by: evaluator
  tokens:      2,341,801 worker · 392,500 subagent (2,734,301 / 3,000,000)
  duration:    2h 14m
```

Came in under budget, took just over two hours, **150 continuation turns**. That's a real autonomous run.

## What if the goal pauses with `budget_limited`?

Suppose the goal stalls and burns through the 3M cap:

```
/goal-status

◎ Goal: refactor src/auth/* to use async/await...
  status:      budget_limited
  tokens:      2,941,820 worker · 58,180 subagent (3,000,000 / 3,000,000)
  continuations remaining: 12 / 150
  paused_reason: budget_limited
```

You have three real options:

**1. Investigate.** Inspect the transcript. Is the model in a loop? Did it misread the task? Is the objective wrong?

**2. Take over manually.** Tell the model directly what to finish. Token accounting still tracks, but the autonomous loop is off.

**3. Start a fresh goal with a higher cap.** If you trust the progress and just need more room:

```
/goal-abandon
/goal-start "<continuation of the prior objective with the remaining work>" --budget 5000000
```

The prior goal's history is preserved in `goal_events` for forensic review.

## Patterns that work

| Pattern | Good for |
|---|---|
| `--budget 500000` | Single-file changes with a quick evaluator pass. Floor for anything meaningful. |
| `--budget 2000000`–`3000000` | Bounded refactors with clear acceptance criteria. The sweet spot for "real work." |
| `--budget 5000000`–`10000000` | Multi-file refactors, doc generation, broad cleanups. |
| `--budget 20000000+` plus `--add-hours 12` | Overnight long-running goals. Set the wall-clock cap to match. |
| No budget | Exploration. Monitor with `/goal-status`. |

## Patterns that don't work

- **Tiny budgets** (`--budget 50000`). One input turn in a real codebase is already 50–100K. The cap will fire on turn one and the plugin will look broken.
- **Vague objectives** (`"clean up the code"`). The evaluator has nothing to verify against.
- **Unverifiable objectives** (`"wait until the build completes"` with no build running). Wall-clock cap eventually catches this, but you waste turns first.
- **Objectives that lie about scope** (`"refactor everything"` with `--budget 200000`). The goal pauses with the work obviously unfinished.

## A budget-sizing intuition

Pessimistically: assume `~30k–60k` tokens *per turn* in a warm cache, `~80k–150k` tokens *per turn* in a cold cache or with heavy file reads.

For a goal you expect to take **N turns**, a safe starting budget is roughly `N × 60k × 1.3` (the `1.3` is headroom). So:

- 30 turns: ~2.3M
- 100 turns: ~7.8M
- 300 turns: ~23M

These are upper bounds. Cache hits routinely cut real usage by 60–80%.
