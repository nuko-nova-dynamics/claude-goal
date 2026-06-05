---
title: State and persistence
description: The SQLite schema, migration runner, audit event log, and how state survives Claude Code restarts.
sidebar:
  order: 4
---

`claude-goal` persists every byte of goal state to SQLite. Restart `claude`, run `--resume`, kill the laptop — the goal still picks up where it left off.

## Storage location

```
${CLAUDE_PLUGIN_DATA}/goals.db
```

`CLAUDE_PLUGIN_DATA` is Claude Code's per-plugin data directory. On macOS that's typically `~/Library/Application Support/Claude/plugins/data/claude-goal/`. Use `/goal-doctor` to print the exact path.

The DB runs in **WAL mode** so concurrent reads (from `/goal-status`, `/goal-history`, statusline) don't block writes (from the Stop hook, MCP server).

## Schema

```sql
CREATE TABLE goals (
  session_id                  TEXT PRIMARY KEY NOT NULL,
  goal_id                     TEXT NOT NULL,
  objective                   TEXT NOT NULL CHECK(length(objective) BETWEEN 1 AND 4000),
  status                      TEXT NOT NULL CHECK(status IN (
                                'active','paused','blocked','budget_limited','complete','abandoned'
                              )),
  paused_reason               TEXT CHECK(paused_reason IN (
                                'user','continuation_cap','wall_clock_cap','cleared',
                                'degraded','accounting_error'
                              ) OR paused_reason IS NULL),
  token_budget                INTEGER,
  budget_profile              TEXT CHECK(budget_profile IN (
                                'quick','standard','deep','overnight'
                              ) OR budget_profile IS NULL),
  budget_source               TEXT NOT NULL DEFAULT 'none' CHECK(budget_source IN (
                                'none','tokens','profile','auto'
                              )),
  tokens_used                 INTEGER NOT NULL DEFAULT 0,
  subagent_tokens             INTEGER NOT NULL DEFAULT 0,
  time_used_seconds           INTEGER NOT NULL DEFAULT 0,
  resume_at_ms                INTEGER,
  last_accounted_byte_offset  INTEGER NOT NULL DEFAULT 0,
  last_accounted_uuid         TEXT,
  accounting_uncertain        INTEGER NOT NULL DEFAULT 0,
  last_continuation_at_ms     INTEGER,
  continuations_remaining     INTEGER NOT NULL DEFAULT 50,
  max_wall_clock_seconds      INTEGER NOT NULL DEFAULT 14400,
  budget_limit_reported       INTEGER NOT NULL DEFAULT 0,
  version                     INTEGER NOT NULL DEFAULT 0,
  created_at_ms               INTEGER NOT NULL,
  updated_at_ms               INTEGER NOT NULL
);

CREATE TABLE goal_events (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id  TEXT NOT NULL,
  goal_id     TEXT NOT NULL,
  hook_name   TEXT,
  event_type  TEXT NOT NULL,
  payload_json TEXT,
  created_at_ms INTEGER NOT NULL
);

CREATE TABLE subagent_token_cursors (
  session_id  TEXT NOT NULL,
  goal_id     TEXT NOT NULL,
  agent_id    TEXT NOT NULL,
  tokens_used INTEGER NOT NULL DEFAULT 0,
  last_accounted_byte_offset INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (session_id, goal_id, agent_id)
);
```

Migration history: v1 initial schema, v2 per-subagent token attribution, v3 `blocked` status, v4 budget profile/source provenance.

The migration runner is in `mcp/goal-server/src/db.ts` — transactional, version-ordered, **downgrade-protected** (the runner refuses to run if `schema_version` exceeds the highest known migration).

## Status enum

```
active           Currently driving turns
paused           User-paused, continuation_cap, or wall_clock_cap
blocked          Waiting for user input or external state after a repeated blocker
budget_limited   Token budget hit
complete         Successfully finished
abandoned        User abandoned
```

`degraded` is a `paused_reason`, not a status. It means a hook caught an unexpected error and paused the goal; `/goal-resume` can restart it after you inspect the issue.

A goal is exclusive per session because `goals.session_id` is the primary key. To start a new goal in the same session, the prior goal must be `complete` or `abandoned`; `active`, `paused`, `blocked`, and `budget_limited` goals must be resumed, extended, completed, or abandoned first.

## Optimistic concurrency

Every `UPDATE` against `goals` must match the current `version` column. The Stop hook and the MCP `update_goal` tool can race — they're both writing to the same row from independent contexts. Optimistic-version checks make the loser silently bail rather than overwriting fresh state.

In practice this matters when the worker calls `update_goal status:complete` mid-turn and the Stop hook fires immediately after — the version check ensures the Stop hook sees the completed state, not its own stale view.

## The event log

`goal_events` records every state transition and accounting event. Selected event kinds:

| Kind | When |
|---|---|
| `goal_created` | `/goal-start` succeeded |
| `goal_completed_by_self_update` | Worker called `update_goal status:complete` directly |
| `goal_completed_by_evaluator` | Worker called `update_goal completed_by:"evaluator"` after a `complete` verdict |
| `goal_blocked` | Worker called `update_goal status:blocked` after a repeated blocker |
| `goal_abandoned` | `/goal-abandon` |
| `goal_paused` | `/goal-pause` or repo pause path |
| `goal_resumed` | `/goal-resume` |
| `budget_limit_reported` | One-shot budget-limit prompt emitted |
| `cap_reached` | Continuation or wall-clock cap reached |
| `paused_degraded` | Hook caught an unexpected error |
| `final_turn_accounted` | F5 retry captured late completion-turn tokens |
| `tokens_accounted` | Worker or subagent token cursor advanced |

`/goal-history --format=json --all` returns these events for post-hoc analysis.

## Surviving `/compact`

Claude Code's `/compact` rewrites the session transcript JSONL — older messages are summarized into a single block, and existing byte cursors into the JSONL become meaningless.

When the SessionStart hook detects `source=compact`, it sets `accounting_uncertain=1` on the active goal and emits a one-shot warning. The Stop hook still drives the loop, but new token accounting is suspect — the cursor is pointed at a different stream now. If a later cursor reset hits an accounting cap, the goal pauses with `paused_reason=accounting_error`.

`/goal-reconcile --accept-reset` clears the flag, resets `transcript_cursor` to the current end-of-file, and resumes. You accept that some tokens between `last_advanced_at` and the `/compact` event are lost — the alternative would be to refuse to continue at all, which is worse.

If the evaluator has already verified the goal as complete, `update_goal status:complete completed_by:"evaluator"` can close a `paused (accounting_error)` goal directly. Self-update completion still cannot bypass that pause.

## Surviving `/clear`

`/clear` creates a new session ID. The old goal's row stays in `goals.db`, **orphaned** — no live session is driving it.

The SessionStart hook detects `source=clear`, logs an orphan-policy event, but does not auto-abandon — that would be a destructive default. Instead you reap orphans manually:

```
/goal-cleanup --list                       # see orphans
/goal-cleanup --delete --older-than 24     # delete those >24h old
```

The 24h default protects fresh paused goals from being clobbered by mistake.

## Backup and inspection

The DB is a regular SQLite file. Standard tooling works:

```bash
# Print the active goal
sqlite3 $CLAUDE_PLUGIN_DATA/goals.db \
  "SELECT id, status, tokens_used, subagent_tokens FROM goals WHERE status='active'"

# Tail the event log
sqlite3 $CLAUDE_PLUGIN_DATA/goals.db \
  "SELECT ts, kind, payload FROM goal_events ORDER BY id DESC LIMIT 20"

# Backup
sqlite3 $CLAUDE_PLUGIN_DATA/goals.db ".backup /tmp/goals-backup.db"
```

WAL mode means hot backups via `.backup` are consistent without locking.
