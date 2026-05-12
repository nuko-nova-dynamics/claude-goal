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
-- v1: initial schema
CREATE TABLE goals (
  id                       INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id               TEXT NOT NULL,
  objective                TEXT NOT NULL,
  status                   TEXT NOT NULL,
  paused_reason            TEXT,
  token_budget             INTEGER,
  tokens_used              INTEGER NOT NULL DEFAULT 0,
  continuations_total      INTEGER NOT NULL,
  continuations_remaining  INTEGER NOT NULL,
  wall_clock_cap_seconds   INTEGER NOT NULL,
  started_at               INTEGER NOT NULL,
  last_advanced_at         INTEGER,
  completed_at             INTEGER,
  completed_by             TEXT,
  accounting_uncertain     INTEGER NOT NULL DEFAULT 0,
  transcript_cursor        INTEGER NOT NULL DEFAULT 0,
  version                  INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE goal_events (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  goal_id     INTEGER NOT NULL REFERENCES goals(id),
  ts          INTEGER NOT NULL,
  kind        TEXT NOT NULL,
  payload     TEXT
);

-- v2: per-subagent token attribution
ALTER TABLE goals ADD COLUMN subagent_tokens INTEGER NOT NULL DEFAULT 0;

CREATE TABLE subagent_token_cursors (
  goal_id     INTEGER NOT NULL REFERENCES goals(id),
  agent_id    TEXT NOT NULL,
  byte_offset INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (goal_id, agent_id)
);
```

The migration runner is in `mcp/goal-server/src/db.ts` — transactional, version-ordered, **downgrade-protected** (the runner refuses to run if `schema_version` exceeds the highest known migration).

## Status enum

```
active           Currently driving turns
paused           User-paused, continuation_cap, or wall_clock_cap
budget_limited   Token budget hit
complete         Successfully finished
abandoned        User abandoned
degraded         Catch-all error state — /goal-reconcile to recover
```

A goal is exclusive per session — a unique partial index ensures only one `active`/`paused`/`budget_limited` goal can exist per `session_id` at a time. To start a new goal in the same session, abandon the prior one.

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
| `goal_abandoned` | `/goal-abandon` |
| `goal_paused_by_user` | `/goal-pause` |
| `goal_resumed` | `/goal-resume` |
| `goal_budget_limited` | Token budget breached |
| `goal_paused_continuation_cap` | 0 continuations remaining |
| `goal_paused_wall_clock_cap` | Wall-clock cap reached |
| `goal_extended_continuations` | `/goal-extend --add-continuations N` |
| `goal_extended_hours` | `/goal-extend --add-hours N` |
| `goal_reconciled` | `/goal-reconcile --accept-reset` |
| `goal_degraded` | Hook caught an unexpected error |
| `final_turn_accounted` | F5 retry captured late completion-turn tokens |
| `accounting_uncertain_set` | `/compact` rewrote transcript; cursor invalidated |

`/goal-history --format=json --all` returns these events for post-hoc analysis.

## Surviving `/compact`

Claude Code's `/compact` rewrites the session transcript JSONL — older messages are summarized into a single block, and existing byte cursors into the JSONL become meaningless.

When the SessionStart hook detects `source=compact`, it sets `accounting_uncertain=1` on the active goal and emits a one-shot warning. The Stop hook still drives the loop, but new token accounting is suspect — the cursor is pointed at a different stream now.

`/goal-reconcile --accept-reset` clears the flag, resets `transcript_cursor` to the current end-of-file, and resumes. You accept that some tokens between `last_advanced_at` and the `/compact` event are lost — the alternative would be to refuse to continue at all, which is worse.

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
