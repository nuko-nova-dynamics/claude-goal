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
/goal-start "<objective>" [--budget quick|standard|deep|overnight|auto|N]
```

Start a new autonomous goal. Replaces any prior `complete` or `abandoned` goal for this session. Fails if an `active`, `paused`, `blocked`, or `budget_limited` goal already exists — abandon it first.

- `<objective>` — quoted. Concrete, achievable objectives work best. Auto-mode's classifier may block vague objectives like `"do the task"`.
- `--budget quick|standard|deep|overnight` — optional. Selects a full run envelope: token budget, continuation cap, and wall-clock cap.
- `--budget auto` — optional. Deterministically picks a profile from the objective. Explicit overnight/weekend wording selects `overnight`; broad migrations, redesigns, integrations, or repo-wide work select `deep`; bounded features and bug fixes with tests select `standard`; small inspection-style work falls back to `quick`.
- `--budget N` — optional advanced form. Sets a raw hard cap on `(tokens_used + subagent_tokens)` and leaves turn/wall-clock at the practical-unlimited defaults.
- Omit `--budget` for practical-unlimited token, turn, and wall-clock budget.

You can also start a goal with explicit natural language:

```
set up a goal to refactor the auth module to async/await and keep going
make this a goal with a deep budget: migrate the billing integration and verify tests
```

This is intentionally explicit. Ordinary prompts like "fix this bug" do not become goals on their own. When the prose request does not include a budget, Claude calls `create_goal` without `token_budget` or `budget_profile`, so the goal is unbounded. Ask for `quick`, `standard`, `deep`, `overnight`, `auto`, or a raw token number only when you want a limiter.

### `/goal-status`

```
/goal-status
```

Show the active goal's status, budget profile/source, token totals, continuations remaining, wall-clock used, and any warnings (e.g. `accounting_uncertain` after `/compact`).

### `/goal-pause` · `/goal-resume`

```
/goal-pause
/goal-resume
```

User pause/resume. While paused, the Stop hook stops emitting continuations but token accounting still runs (the model can still respond manually if you address it directly). `/goal-resume` also restarts a `blocked` goal after the blocker is resolved.

`/goal-resume` only works on user-paused, degraded, or blocked goals. For cap-paused goals use `/goal-extend`.

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
/goal-extend --add-tokens N
```

Raise a cap or token budget and resume when the matching state is extendable.

- `--add-continuations N` — only valid when `paused_reason=continuation_cap`. Adds N turns and resumes.
- `--add-hours N` — only valid when `paused_reason=wall_clock_cap`. Adds N hours to the wall-clock cap and resumes.
- `--add-tokens N` — valid for `active` or `budget_limited` goals. Adds N tokens to the current budget; for unbudgeted active goals, sets the budget to `tokens_used + subagent_tokens + N`. Resumes budget-limited goals.

All three flags require positive integers and are mutually exclusive.

## Maintenance

### `/goal-reconcile`

```
/goal-reconcile --accept-reset
```

Clear the `accounting_uncertain` flag set after `/compact` or a cursor reset. Resets `transcript_cursor` to the current end-of-file. Resumes the goal if it was paused for `accounting_error`.

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

Returns one row per tracked goal. Columns: status, paused reason, worker tokens, subagent tokens, time started, time elapsed, continuations remaining, budget profile, budget source, and token budget.

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
