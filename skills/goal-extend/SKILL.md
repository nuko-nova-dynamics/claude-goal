---
name: goal-extend
description: Extend a paused or budget-limited goal. Use --add-continuations N for continuation caps, --add-hours N for wall-clock caps, or --add-tokens N for token-budget caps. Resumes when the matching cap is extended.
disable-model-invocation: true
allowed-tools:
  - Bash
---

The user invoked /goal-extend with arguments: $ARGUMENTS

Run this command via the Bash tool and report only its output. Do not call any other tools.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/goal-cli.sh" extend --session-id "${CLAUDE_SESSION_ID}" $ARGUMENTS
```
