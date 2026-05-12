---
name: goal-history
description: List past and current goals for this session (or all sessions with --all). Shows objective, status, tokens used, time, and continuations remaining for each goal. Pass --format=json for machine-readable output.
disable-model-invocation: true
---

The user invoked /goal-history with arguments: $ARGUMENTS

Run this command via the Bash tool and report only its output. Do not call any other tools.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/goal-cli.sh" history --session-id "${CLAUDE_SESSION_ID}" $ARGUMENTS
```
