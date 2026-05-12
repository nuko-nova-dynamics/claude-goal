---
name: goal-stop
description: Alias for /goal-abandon. Abandons the current goal and stops the auto-continuation loop. Mirrors the multi-alias convention from Claude Code's native /goal (clear, stop, off, reset, cancel).
disable-model-invocation: true
---

The user invoked /goal-stop. Run this command via the Bash tool and report only its output. Do not call any other tools.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/goal-cli.sh" abandon --session-id "${CLAUDE_SESSION_ID}"
```
