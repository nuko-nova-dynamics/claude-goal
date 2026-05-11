---
name: goal-pause
description: Pause the active goal. The agent will not auto-continue while paused.
disable-model-invocation: true
---

The user invoked /goal-pause. Run this command via the Bash tool and report only its output. Do not call any other tools.

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/goal-cli.sh pause
```
