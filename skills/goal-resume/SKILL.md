---
name: goal-resume
description: Resume a goal previously paused by /goal-pause. Cap-paused goals require /goal-extend instead.
disable-model-invocation: true
---

The user invoked /goal-resume. Run this command via the Bash tool and report only its output. Do not call any other tools.

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/goal-cli.sh resume --session-id ${CLAUDE_SESSION_ID}
```
