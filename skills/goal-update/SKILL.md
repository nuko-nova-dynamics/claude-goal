---
name: goal-update
description: This skill should be used when the user invokes /goal-update with a new objective, or explicitly asks to change, refine, expand, or re-scope what the current claude-goal should accomplish mid-run (for example, "update the goal to also cover X" or "change the goal objective to Y"). Replaces the objective of the active or budget-limited goal while keeping its budget, token accounting, and history. Do not use this skill to start a new goal, to stop one, or to narrow an objective so it is easier to complete.
allowed-tools:
  - mcp__plugin_claude-goal_goal__update_objective
  - mcp__plugin_claude-goal_goal__get_goal
---

The user explicitly asked to change what the current goal should accomplish. The request may be either:

- Slash form: `/goal-update "new objective"`
- Natural-language form: "update the goal to ...", "change the goal so it also covers ...", or similar explicit re-scoping wording

Arguments: $ARGUMENTS

Determine the new objective:

- Slash form: use the quoted objective string.
- Natural-language form: derive the full replacement objective from the user's wording. When the user is adding to or refining the existing objective rather than replacing it, call `get_goal` first and compose the new objective from the current one plus the requested change, preserving every constraint that still applies.
- If no concrete objective is recoverable, ask one concise clarification question instead of guessing.

Call the `update_objective` MCP tool with:
- `session_id`: (the system will provide this; if not, call `get_goal` first to discover it)
- `objective`: the new objective (1-4000 characters)

After the tool returns:
- If success: briefly confirm the updated objective and continue working toward it. Budgets, token accounting, and goal history carry over unchanged.
- If it fails because the goal is paused or blocked: report that and suggest `/goal-resume` (or `/goal-extend` for cap-paused goals) before updating.
- If it fails because no goal exists: suggest `/goal-start` instead.
- For any other error: report it verbatim.

Never use this tool on your own initiative to shrink or simplify the objective; only the user re-scopes a goal.
