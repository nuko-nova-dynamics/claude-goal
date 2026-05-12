---
title: Quickstart
description: Start your first goal, watch the loop run, and stop it cleanly.
sidebar:
  order: 2
---

This page walks through a single autonomous goal end-to-end. Five minutes.

## 1. Start a goal

```
/goal-start "list every .ts file under src/ and print a line count for each"
```

Claude confirms the objective and begins working. The plugin has:

1. Inserted a row into `goals.db` with `status=active`
2. Stored the session ID so the Stop hook knows the goal is yours
3. Initialized `tokens_used=0`, `subagent_tokens=0`, `continuations_remaining=50`, and a 4-hour wall-clock cap

## 2. Watch the loop run

Every assistant turn ends with the Stop hook. The hook reads the transcript JSONL, sums new tokens, updates the DB, then either:

- emits `{"decision":"block","reason":"<continuation prompt>"}` — Claude Code feeds the prompt back to the model for the next turn
- emits a budget-limit / cap-reached prompt and stops if a threshold is hit
- stays silent if the worker has already called `update_goal` to mark complete

While the loop runs you can check status at any time:

```
/goal-status
```

Returns something like:

```
◎ Goal: list every .ts file under src/ and print a line count for each
  status:      active
  tokens:      12,418 worker · 2,103 subagent (14,521 total)
  continuations remaining: 47 / 50
  wall-clock used: 0h 03m / 4h
```

## 3. Add a budget

Cancel the goal and start over with a hard token cap:

```
/goal-abandon
/goal-start "list every .ts file under src/ and print a line count for each" --budget 25000
```

When `(tokens_used + subagent_tokens) >= 25000`, the hook transitions the goal to `budget_limited` and emits the one-shot budget-limit prompt. The model sees that prompt, knows the goal is paused, and stops trying to continue.

To raise the cap and resume:

```
/goal-extend --add-continuations 10
```

## 4. Pause + resume

```
/goal-pause
```

Hook now stays silent until you explicitly resume:

```
/goal-resume
```

`/goal-pause` is the safe brake — token accounting still tracks, but the model is not pushed to continue.

## 5. Stop cleanly

```
/goal-abandon
```

(or its alias `/goal-stop`)

The goal transitions to `abandoned`, the Stop hook stops injecting continuations, and the row stays in `goals.db` for `/goal-history` to find.

## What just happened

1. **Stop hook** drove the agent across turns by emitting continuation prompts.
2. **PostToolBatch hook** sat in the background, summing tokens after every tool batch.
3. **MCP server** (the `claude-goal` MCP) gave the worker `create_goal` / `get_goal` / `update_goal` tools.
4. **Evaluator subagent** (would have) verified the objective by querying the DB and running tools before marking complete.
5. **F5 final-turn retry** caught the completion turn's tokens after `update_goal` fired.

[How it works →](/concepts/how-it-works/)
