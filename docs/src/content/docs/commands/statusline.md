---
title: Statusline
description: Wire the bundled status.sh into Claude Code's statusline for an always-visible goal indicator.
sidebar:
  order: 2
---

`claude-goal` ships a statusline script that renders the active goal's status in Claude Code's status bar.

## Setup

Add this to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/path/to/claude-goal/statusline/status.sh"
  }
}
```

Replace `/path/to/claude-goal` with the absolute path to the installed plugin. If you installed via the marketplace, the path is typically:

```
~/.claude/plugins/marketplaces/nuko-nova-tools/claude-goal/statusline/status.sh
```

For a `--plugin-dir` install, it's whatever you passed to `--plugin-dir` followed by `/statusline/status.sh`.

## What it shows

| Output | State |
|---|---|
| `◎ goal active (1.2M / 5M)` | Active with a token budget |
| `◎ goal active (800K)` | Active, no budget set |
| `◎ goal paused (user)` | User-paused via `/goal-pause` |
| `◎ goal paused (continuation_cap)` | Out of continuations |
| `◎ goal paused (wall_clock_cap)` | Wall-clock cap reached |
| `◎ goal unmet (budget exhausted)` | `status=budget_limited` |
| `◎ goal achieved` | `status=complete` |
| `◎ goal abandoned` | `status=abandoned` |
| (empty) | No goal for this session |

The token total shown is `tokens_used + subagent_tokens` — the full billable count, same number used for budget enforcement.

Token formatting:

- `< 1000` → raw count
- `1000–999,999` → `XK` (integer)
- `>= 1,000,000` → `XM` when divisible, otherwise `X.XM` (one-decimal, truncated)

## Refresh frequency

Claude Code refreshes statusline commands every few seconds. The script is intentionally cheap — a single SQLite query against the session's active goal. Cost per refresh: < 5 ms on a warm DB.

## Custom statuslines

The script is plain bash. If you want a custom format, copy `statusline/status.sh` and edit. The query is short:

```bash
sqlite3 "$CLAUDE_PLUGIN_DATA/goals.db" \
  "SELECT status, paused_reason, tokens_used, subagent_tokens, token_budget
   FROM goals
   WHERE session_id = '$CLAUDE_SESSION_ID'
   ORDER BY started_at DESC LIMIT 1"
```

Format the row however you like and `echo` the result.
