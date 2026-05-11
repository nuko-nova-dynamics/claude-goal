---
name: goal-start
description: Start a new autonomous goal. The agent self-drives turns until the model passes a completion audit. Complements Claude Code's native /goal by adding deterministic token budgets, pause/resume, /extend, and persistence across restart.
---

The user invoked /goal-start. Parse the arguments below — the objective is the quoted string, optionally followed by `--budget N`.

Arguments: $ARGUMENTS

Call the `create_goal` MCP tool with:
- `session_id`: (the system will provide this; if your environment does not auto-supply it, call `get_goal` first to discover it, or ask the user for the session id)
- `objective`: the quoted objective string
- `token_budget`: the integer after `--budget`, or omit if not given

After the tool returns:
- If success: briefly confirm the goal is active, restate the objective, mention the token budget if any, then begin work.
- If error: report the error to the user verbatim.

From now until the goal is marked complete, after every turn the system will inject a continuation prompt. Keep working toward the objective. When you have built and verified a prompt-to-artifact checklist showing every requirement is met, call `update_goal` with `status: "complete"`. Do not mark complete on partial progress.
