---
name: goal-start
description: This skill should be used when the user invokes /goal-start with a quoted objective and optional --budget value. Creates a new autonomous goal that self-drives turns until the model passes its completion audit. Complements Claude Code's native /goal by adding deterministic token budgets, budget profiles, pause/resume, /goal-extend, and persistence across claude restart.
allowed-tools:
  - mcp__plugin_claude-goal_goal__create_goal
  - mcp__plugin_claude-goal_goal__get_goal
  - mcp__plugin_claude-goal_goal__update_goal
  - Agent
---

The user invoked /goal-start. Parse the arguments below — the objective is the quoted string, optionally followed by `--budget VALUE`.

Arguments: $ARGUMENTS

Call the `create_goal` MCP tool with:
- `session_id`: (the system will provide this; if your environment does not auto-supply it, call `get_goal` first to discover it, or ask the user for the session id)
- `objective`: the quoted objective string
- If `--budget` is omitted: omit both `token_budget` and `budget_profile`; the goal is unbounded.
- If `--budget` is a positive integer: set `token_budget` to that integer and omit `budget_profile`.
- If `--budget` is one of `quick`, `standard`, `deep`, `overnight`, or `auto`: set `budget_profile` to that string and omit `token_budget`.
- If `--budget` is anything else: report that the budget must be a positive integer or one of `quick`, `standard`, `deep`, `overnight`, `auto`.

After the tool returns:
- If success: briefly confirm the goal is active, restate the objective, mention the budget profile or token budget if any, then begin work.
- If error: report the error to the user verbatim.

From now until the goal is marked complete, after every turn the system will inject a continuation prompt. Keep working toward the objective.

Before marking the goal complete, build and verify a prompt-to-artifact checklist showing every requirement is met. Then dispatch the plugin subagent `claude-goal:goal-evaluator` with the Agent tool (Task is an older alias if Agent is unavailable). Pass the session id, objective, checklist, transcript path if known, and concrete evidence. If it returns `{"verdict":"complete"}`, call `update_goal` with `status: "complete"` and `completed_by: "evaluator"`.

If the evaluator is unavailable, blocked, or explicitly skipped by the user, keep the worker-only fallback: use your own completion audit and call `update_goal` with `status: "complete"` only when the goal is complete. Do not mark complete on partial progress.

If the same blocker repeats across at least three consecutive continuation turns and no meaningful progress is possible without user input or an external-state change, call `update_goal` with `status: "blocked"` and a concise `blocked_reason`. Do not use blocked for work that is merely hard, slow, uncertain, or under-verified.
