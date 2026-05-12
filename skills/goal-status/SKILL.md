---
name: goal-status
description: Display the current goal's status, budget, and remaining capacity.
disable-model-invocation: true
---

The user invoked /goal-status. Run this command via the Bash tool and report only its output. Do not call any other tools.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/goal-cli.sh" status --session-id "${CLAUDE_SESSION_ID}"
```
