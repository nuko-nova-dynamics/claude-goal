---
name: goal-reconcile
description: Clear the accounting_uncertain flag set after /compact. Use --accept-reset to acknowledge that token accounting from before the compaction is lost; the goal resumes if it was paused for accounting_error.
disable-model-invocation: true
---

The user invoked /goal-reconcile with arguments: $ARGUMENTS

Run this command via the Bash tool and report only its output. Do not call any other tools.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/goal-cli.sh" reconcile --session-id "${CLAUDE_SESSION_ID}" $ARGUMENTS
```
