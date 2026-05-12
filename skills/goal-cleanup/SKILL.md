---
name: goal-cleanup
description: List or delete orphaned goals (those left behind by /clear). Use --list to see stale rows; --delete to remove them; --older-than HOURS to filter (default 24).
disable-model-invocation: true
---

The user invoked /goal-cleanup with arguments: $ARGUMENTS

Run this command via the Bash tool and report only its output. Do not call any other tools.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/goal-cli.sh" cleanup $ARGUMENTS
```
