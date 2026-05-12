---
title: Recover from /compact
description: When Claude Code rewrites the transcript, the accounting flag flips. Here's how to reconcile cleanly.
sidebar:
  order: 2
---

Claude Code's `/compact` rewrites the session transcript JSONL — older messages collapse into a summary block, and any byte cursor into the prior JSONL becomes meaningless. `claude-goal` notices and protects you.

## What happens automatically

1. You run `/compact` during an active goal.
2. The next time SessionStart fires (on the next session restore or hook trigger), the hook detects `source=compact`.
3. The active goal's `accounting_uncertain` flag flips to `1`.
4. The next Stop hook fire emits a one-shot warning to the model and pauses the goal with `paused_reason=accounting_uncertain`.

```
/goal-status

◎ Goal: <objective>
  status:      paused
  paused_reason: accounting_uncertain
  tokens:      24,500 worker · 1,800 subagent  (last known — may undercount)
  ⚠ /compact event detected. Run /goal-reconcile --accept-reset to resume.
```

## Why pause, not auto-reset

The cursor pointed at byte offset N in the old JSONL. After `/compact`, byte offset N in the new JSONL is **a different point in time**. Continuing to advance from there would either double-count (if N is now earlier in the conversation) or undercount (if N is now beyond the relevant assistant turns).

Neither failure mode is acceptable silently. So the plugin pauses and waits for you to acknowledge the trade-off.

## Reconcile and resume

```
/goal-reconcile --accept-reset
```

The `--accept-reset` flag is intentional — it makes you confirm:

> Yes, I accept that token accounting between `last_advanced_at` and the `/compact` event is unrecoverable. Reset the cursor to the current end-of-file and resume from now.

The command:

1. Clears `accounting_uncertain=0`
2. Resets `transcript_cursor` to the current size of the session JSONL
3. Logs a `goal_reconciled` event with the prior cursor value (for forensic audit)
4. Resumes the goal — status flips back to `active`

The next Stop hook fire starts counting tokens cleanly from the new cursor.

## What you lose

Tokens consumed between `last_advanced_at` and the `/compact` event are lost to accounting. For most goals this is a small fraction of total usage — `/compact` typically fires after the model has worked for many turns, and `last_advanced_at` is usually recent.

If you care about precise post-hoc accounting (e.g. for billing), the `goal_events` log records `accounting_uncertain_set` with the timestamp, so you can manually estimate the undercount window.

## When to abandon instead

If `/compact` fired because the goal was already off the rails (e.g. the model was looping and consuming context), don't reconcile — abandon and start fresh:

```
/goal-abandon
/goal-start "<refined objective>" --budget <new budget>
```

The prior goal's row stays in `goal_history` for reference.

## Preventing the problem

`/compact` is most likely to fire on long-running goals. If a goal is at risk of triggering compact, options:

- **Set a wall-clock cap** — `/goal-extend --add-hours 2` paces the goal in checkpoints.
- **Use `/clear` between phases** — explicitly clears context, orphans the current goal, lets you start fresh. Pair with `/goal-cleanup` to reap the orphan.
- **Tighter objectives** — narrow scope means fewer turns means less risk of compact firing.
