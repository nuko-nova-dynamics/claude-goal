---
title: Run a goal under budget
description: A worked example of starting a goal with a token budget, watching it pause, and resuming with extra turns.
sidebar:
  order: 1
---

This recipe walks through the most common production pattern: a bounded refactor with a hard token cap.

## The scenario

You want Claude to refactor an authentication module to use async/await. The change should be self-contained, the tests should pass, and you don't want to spend more than ~50K tokens.

## Run it

```
/goal-start "refactor src/auth/* to use async/await; preserve existing test contracts; ensure all tests in test/auth/ pass" --budget 50000
```

Notes on the objective:

- **Concrete scope** — `src/auth/*`, not "the auth code"
- **Explicit acceptance criterion** — tests pass in `test/auth/`
- **Constraint** — preserve existing contracts (a hint to the evaluator: contract-breaking refactors → `incomplete`)

## Watch the loop

After a few turns, check status:

```
/goal-status

◎ Goal: refactor src/auth/* to use async/await...
  status:      active
  tokens:      18,234 worker · 0 subagent (18,234 / 50,000)
  continuations remaining: 46 / 50
  wall-clock used: 0h 12m / 4h
```

Worker tokens climb steadily; subagent tokens stay at 0 until the evaluator dispatches.

## When the evaluator fires

The continuation prompt has been telling the worker, on every turn, to dispatch the evaluator before declaring done. Once the worker thinks it's finished, you'll see (in the transcript):

```
[Task] dispatching claude-goal:goal-evaluator with objective + evidence...
```

The evaluator subagent reads the active goal, inspects recent assistant turns, then **runs the tests** (Bash tool). Verdict comes back as JSON:

```json
{
  "verdict": "complete",
  "reason": "Tests in test/auth/ — auth.test.ts (8 tests), session.test.ts (5 tests) — all pass via `npm test test/auth`. async/await replaces .then() chains in src/auth/oauth.ts:23, src/auth/session.ts:41, src/auth/tokens.ts:18. No public API signatures changed."
}
```

The worker reads that verdict, calls `update_goal status:complete completed_by:"evaluator"`, and stops.

Final status:

```
/goal-status

◎ Goal: refactor src/auth/* to use async/await...
  status:      complete
  completed_by: evaluator
  tokens:      32,841 worker · 4,205 subagent (37,046 / 50,000)
  duration:    23m 18s
```

Came in well under budget.

## What if it hits the budget?

Suppose instead the goal stalls and burns through tokens. At 50K:

```
/goal-status

◎ Goal: refactor src/auth/* to use async/await...
  status:      budget_limited
  tokens:      47,820 worker · 2,180 subagent (50,000 / 50,000)
  continuations remaining: 38 / 50
  paused_reason: budget_limited
```

The Stop hook has emitted the one-shot **budget-limit prompt** to the model, telling it not to try to continue. The model has stopped self-driving.

You have three options:

**1. Investigate.** Inspect the transcript. Is the model in a loop? Did it misread the task? Is the objective wrong?

**2. Raise turns, accept overrun.** If you trust the model to finish and just need a few more turns:

```
/goal-extend --add-continuations 10
```

But the goal is `budget_limited` not `continuation_cap`, so on the next turn the hook will re-detect over-budget and re-pause. **This works only if you also accept the overrun** — which means you need a new goal with a higher budget:

```
/goal-abandon
/goal-start "<continuation of the prior objective>" --budget 100000
```

**3. Take over manually.** Tell the model directly what to finish. Token accounting still tracks, but the autonomous loop is off.

## Patterns that work

| Pattern | Good for |
|---|---|
| `--budget 10000` | Single-file changes, sanity checks. If it hits the cap, something's wrong. |
| `--budget 30-50K` | Bounded refactors with clear acceptance criteria. The sweet spot. |
| `--budget 100K` | Multi-file refactors, doc generation, broad cleanups. |
| `--budget 200K+` plus `--add-hours 8` | Overnight long-running goals. |
| No budget | Exploratory "let me see how far it gets." Monitor with `/goal-status`. |

## Patterns that don't work

- Vague objectives — `"clean up the code"`. The evaluator has nothing to verify.
- Unverifiable objectives — `"wait until the build completes"` with no build running. Wall-clock cap eventually catches this but you waste turns first.
- Objectives that lie about scope — `"refactor everything"` with `--budget 5000`. The goal pauses at 5K with the work obviously unfinished.
