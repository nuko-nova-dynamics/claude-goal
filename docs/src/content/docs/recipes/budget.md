---
title: Run a goal under budget
description: A worked example of an autonomous refactor with a budget profile, watching caps, and resuming with extra room.
sidebar:
  order: 1
---

This recipe walks through what a **real** autonomous goal looks like: hours of wall-clock time, many turns, profile-sized token headroom.

## The scenario

You want Claude to refactor an authentication module to use async/await. Multiple files, contract preservation, tests must pass. You expect this to take **1–3 hours of model time** if it works end-to-end.

## Pick the profile for the shape of the work

```
/goal-start "refactor src/auth/* to use async/await; preserve existing test contracts; ensure all tests in test/auth/ pass" --budget deep
```

Notes on the objective and the profile:

- **Concrete scope** — `src/auth/*`, not "the auth code"
- **Explicit acceptance criterion** — tests pass in `test/auth/`
- **Constraint** — preserve existing contracts (a hint to the evaluator: contract-breaking refactors → `incomplete`)
- **`deep` profile** — 5M tokens, 150 continuations, and 8 hours. That leaves room for a multi-file refactor plus evaluator feedback without manually sizing three caps.

## What the loop looks like at minute 15

```
/goal-status

◎ Goal: refactor src/auth/* to use async/await...
  status:      active
  budget:      deep profile
  tokens:      612,043 worker · 84,200 subagent (696,243 / 5,000,000)
  continuations remaining: 112 / 150
  wall-clock used: 0h 15m / 8h
```

Worker has read several files, made initial changes, and the evaluator has dispatched once to check progress (subagent tokens are non-zero). The cache has warmed — subsequent turns are cheap.

## If the continuation cap fires

Profile caps are intentionally larger than the unprofiled defaults, but a real refactor can still burn through its continuation budget before completion:

```
/goal-status

◎ Goal: refactor src/auth/* to use async/await...
  status:      paused
  paused_reason: continuation_cap
  budget:      deep profile
  tokens:      2,401,328 worker · 311,400 subagent (2,712,728 / 5,000,000)
  continuations remaining: 0 / 150
  wall-clock used: 2h 47m / 8h
```

The token budget is fine. The turn cap fired. Extend it:

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
  budget:      deep profile
  tokens:      2,341,801 worker · 392,500 subagent (2,734,301 / 5,000,000)
  duration:    2h 14m
```

Came in under budget, took just over two hours, and stayed inside the `deep` run envelope. That's a real autonomous run.

## What if the goal reaches `budget_limited`?

Suppose the goal stalls and burns through the 5M cap:

```
/goal-status

◎ Goal: refactor src/auth/* to use async/await...
  status:      budget_limited
  budget:      deep profile
  tokens:      4,941,820 worker · 58,180 subagent (5,000,000 / 5,000,000)
  continuations remaining: 12 / 150
```

You have three real options:

**1. Investigate.** Inspect the transcript. Is the model in a loop? Did it misread the task? Is the objective wrong?

**2. Take over manually.** Tell the model directly what to finish. Token accounting still tracks, but the autonomous loop is off.

**3. Raise the token budget and resume.** If you trust the progress and just need more room:

```
/goal-extend --add-tokens 2000000
```

This keeps the same goal row, preserves the audit trail, and resumes from the budget-limited state.

If the transcript shows looping or the objective needs to be narrowed, abandon and restart with a better objective instead.

## Patterns that work

| Pattern | Good for |
|---|---|
| `--budget quick` | Single-file changes, inspection, or quick evaluator passes. |
| `--budget standard` | Bounded features, bug fixes with tests, and medium refactors. |
| `--budget deep` | Multi-file refactors, migrations, doc generation, broad cleanups, integrations. |
| `--budget overnight` | Explicit overnight/weekend long-running goals. |
| `--budget auto` | Let deterministic objective matching pick one of the profiles. |
| No budget | Exploration. Monitor with `/goal-status`. |

## Patterns that don't work

- **Tiny raw budgets** (`--budget 50000`). One input turn in a real codebase is already 50–100K. The cap will fire on turn one and the plugin will look broken.
- **Vague objectives** (`"clean up the code"`). The evaluator has nothing to verify against.
- **Unverifiable objectives** (`"wait until the build completes"` with no build running). Wall-clock cap eventually catches this, but you waste turns first.
- **Objectives that lie about scope** (`"refactor everything"` with `--budget quick`). The goal pauses with the work obviously unfinished.

## Advanced token-sizing intuition

Raw token numbers are still supported, but they are the advanced path. If you choose to use them:

Pessimistically: assume `~30k–60k` tokens *per turn* in a warm cache, `~80k–150k` tokens *per turn* in a cold cache or with heavy file reads.

For a goal you expect to take **N turns**, a safe starting budget is roughly `N × 60k × 1.3` (the `1.3` is headroom). So:

- 30 turns: ~2.3M
- 100 turns: ~7.8M
- 300 turns: ~23M

These are upper bounds. Cache hits routinely cut real usage by 60–80%.
