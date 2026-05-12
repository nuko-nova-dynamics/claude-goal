---
name: goal-extend
description: Extend a cap-paused goal. Use --add-continuations N to add N more continuation turns, or --add-hours N to extend the wall-clock window. Resumes the goal automatically.
disable-model-invocation: true
---

The user invoked /goal-extend with arguments: $ARGUMENTS

Run this command via the Bash tool and report only its output. Do not call any other tools.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/goal-cli.sh" extend --session-id "${CLAUDE_SESSION_ID}" $ARGUMENTS
```
