---
name: goal-doctor
description: Run a self-test to confirm claude-goal is healthy. Use when troubleshooting why goals aren't behaving as expected.
disable-model-invocation: true
allowed-tools:
  - Bash
---

The user invoked /goal-doctor. Run this command via the Bash tool and report only its output. Do not call any other tools.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/goal-cli.sh" doctor
```
