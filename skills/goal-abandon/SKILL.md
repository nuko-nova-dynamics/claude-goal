---
name: goal-abandon
description: Abandon the current goal. Stops the auto-continuation loop and marks the goal abandoned.
disable-model-invocation: true
---

The user invoked /goal-abandon. Run this command via the Bash tool and report only its output. Do not call any other tools.

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/goal-cli.sh abandon
```
