---
title: Reap orphaned goals
description: When /clear orphans a goal, here's how to find and clean up the leftover rows.
sidebar:
  order: 3
---

`/clear` creates a new Claude Code session ID. Any goal tied to the old session ID is **orphaned** — no live session is driving it anymore. The row stays in `goals.db` until you reap it.

## See orphans

```
/goal-cleanup --list
```

Shows every orphaned goal regardless of age:

```
orphaned goals:
  id=12  status=paused           started=2026-05-10 14:22  age=2d 1h
  id=18  status=active           started=2026-05-11 09:45  age=18h
  id=23  status=budget_limited   started=2026-05-12 03:11  age=22m
```

`age` is computed from `started_at` to now.

## Filter by age

```
/goal-cleanup --list --older-than 24
```

Show orphans older than 24 hours. Useful when you've just run `/clear` and want to see only the truly stale rows.

## Delete

```
/goal-cleanup --delete
```

**Default behavior** — deletes orphans older than 24 hours. The 24h default is intentional protection so you don't accidentally clobber a recent paused goal you might want to resume.

```
/goal-cleanup --delete --older-than 1
```

Override the default — delete orphans older than 1 hour. Useful after a session of heavy `/clear` usage.

```
/goal-cleanup --delete --older-than 0
```

Nuclear option — delete every orphan. Logs each delete to `goal_events` so the audit trail survives.

## What gets deleted

Only goals that are:

1. Owned by a session ID that no longer matches any live session (i.e. orphaned)
2. Not the **current session's** active goal (never deletes your live work)
3. Older than the `--older-than` threshold

The `goals` row, all matching `goal_events`, and any `subagent_token_cursors` are removed in a single transaction.

## Forensic recovery

If you delete a row you wanted to keep, the audit log is gone — but `goal_events` writes are fsync'd through WAL, so a database file backup taken before the delete still has the data. If you take periodic backups of `${CLAUDE_PLUGIN_DATA}/goals.db`, you can restore.

```bash
sqlite3 $CLAUDE_PLUGIN_DATA/goals.db ".backup /tmp/goals-pre-cleanup.db"
```

…before any large cleanup is a cheap insurance policy.

## When to keep orphans

If you do iterative goal work and use `/clear` frequently as a checkpoint, you may **want** the orphan rows around — they're a good `/goal-history --all` audit trail. The 24h `--older-than` default already accommodates that.

`/goal-cleanup --list` is read-only and cheap. Run it whenever you wonder "did I leave a goal hanging?"
