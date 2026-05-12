---
title: Command reference
description: Every claude-goal slash command, what it does, and when to reach for it.
sidebar:
  order: 1
---

Every command lives under the `/goal-*` namespace.

## Lifecycle

### `/goal-start`

```
/goal-start "<objective>" [--budget N]
```

Start a new autonomous goal. Replaces any prior `complete` or `abandoned` goal for this session. Fails if an `active`, `paused`, or `budget_limited` goal already exists — abandon it first.

- `<objective>` — quoted. Concrete, achievable objectives work best. Auto-mode's classifier may block vague objectives like `"do the task"`.
- `--budget N` — optional. Hard cap on `(tokens_used + subagent_tokens)`. When breached, goal pauses with `paused_reason=budget_limited`.

### `/goal-status`

```
/goal-status
```

Show the active goal's status, token totals, continuations remaining, wall-clock used, and any warnings (e.g. `accounting_uncertain` after `/compact`).

### `/goal-pause` · `/goal-resume`

```
/goal-pause
/goal-resume
```

User pause/resume. While paused, the Stop hook stops emitting continuations but token accounting still runs (the model can still respond manually if you address it directly).

`/goal-resume` only works on user-paused goals. For cap-paused goals use `/goal-extend`.

### `/goal-abandon`

```
/goal-abandon
/goal-stop          # alias
```

Mark the goal `abandoned`. Permanent — the row stays in `goals.db` for history but the Stop hook stops driving it.

### `/goal-extend`

```
/goal-extend --add-continuations N
/goal-extend --add-hours N
```

Raise a cap on a paused goal and resume it.

- `--add-continuations N` — only valid when `paused_reason=continuation_cap`. Adds N turns and resumes.
- `--add-hours N` — only valid when `paused_reason=wall_clock_cap`. Adds N hours to the wall-clock cap and resumes.

`--add-continuations` is also the right move for a `budget_limited` goal — adds turns so the model can wrap up cleanly. **Note** that it doesn't raise the token budget itself; if the goal is still over budget it'll re-pause immediately.

## Maintenance

### `/goal-reconcile`

```
/goal-reconcile --accept-reset
```

Clear the `accounting_uncertain` flag set after `/compact`. Resets `transcript_cursor` to the current end-of-file. Resumes the goal if it was paused for `accounting_uncertain` specifically.

`--accept-reset` is required — the flag exists explicitly so you opt in to "yes, I know I'm losing some token accounting between the last advance and the compact event."

### `/goal-doctor`

```
/goal-doctor
```

Preflight self-test. Checks:

| Check | What it validates |
|---|---|
| SQLite | `sqlite3` on PATH, can open `goals.db`, WAL mode enabled |
| MCP | `claude-goal` MCP server registered and responding |
| Hooks | Stop hook + PostToolBatch hook + SessionStart hook all registered |
| Shell | `jq`, `bash`, `tr`, `cut`, `sed` all on PATH |
| Plugin data dir | `${CLAUDE_PLUGIN_DATA}` exists and is writable |

Exit 0 with a green report = ready to use. Anything red is a config issue to fix before `/goal-start`.

## History + cleanup

### `/goal-history`

```
/goal-history                        # just this session
/goal-history --all                  # all sessions, newest first
/goal-history --format=json          # machine-readable
/goal-history --format=json --all
```

Returns one row per tracked goal. Columns: status, paused reason, worker tokens, subagent tokens, time started, time elapsed, continuations remaining, budget.

`--format=json` is the audit hook — pipe it to `jq` for analysis.

### `/goal-cleanup`

```
/goal-cleanup --list                 # show orphans
/goal-cleanup --list --older-than 1  # show orphans older than 1h

/goal-cleanup --delete               # delete orphans older than 24h (default)
/goal-cleanup --delete --older-than 48
```

`/clear` creates a new session ID and orphans the prior goal's row. `/goal-cleanup` surfaces and reaps those orphans.

The default `--older-than 24` (hours) protects fresh paused goals. Pass an explicit value to override.

## Exit codes

All commands exit:

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | User-recoverable error (e.g. no active goal, version conflict) |
| 2 | System error (e.g. SQLite unavailable, MCP not registered) |
