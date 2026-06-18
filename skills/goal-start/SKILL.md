---
name: goal-start
description: This skill should be used when the user invokes /goal-start with a quoted objective and optional --budget value, or when the user explicitly asks in natural language to set up, start, create, or use a claude-goal for the current work (for example, "set up a goal and continue", "make this a goal", or "start a claude-goal for this"). Do not use this skill for ordinary tasks that do not explicitly ask for a goal. Creates a new autonomous goal that self-drives turns until the model passes its completion audit. Complements Claude Code's native /goal by adding deterministic token budgets, budget profiles, pause/resume, /goal-extend, and persistence across claude restart.
allowed-tools:
  - mcp__plugin_claude-goal_goal__create_goal
  - mcp__plugin_claude-goal_goal__get_goal
  - mcp__plugin_claude-goal_goal__update_goal
  - mcp__plugin_claude-goal_goal__resume_goal
  - mcp__plugin_claude-goal_goal__abandon_goal
  - Agent
---

The user explicitly requested a claude-goal. The request may be either:

- Slash form: `/goal-start "objective" [--budget VALUE]`
- Natural-language form: "set up a goal and continue", "make this a goal", "start a claude-goal for this", or similar explicit goal-start wording

Arguments: $ARGUMENTS

Determine the objective:

- Slash form: use the quoted objective string, optionally followed by `--budget VALUE`.
- Natural-language form: derive the objective from the user's requested work, preserving concrete constraints and acceptance criteria. Remove only the meta instruction to set up/start/create/use a goal.
- If no concrete objective is recoverable, ask one concise clarification question instead of creating a vague goal.

Determine the budget:

- If the user did not explicitly ask for a budget, limiter, cap, token count, or profile: omit both `token_budget` and `budget_profile`; the goal is unbounded. This applies to slash form and natural-language form.
- If the user explicitly asks for no budget, unbounded, or unlimited: omit both `token_budget` and `budget_profile`.
- If the user explicitly provides `quick`, `standard`, `deep`, `overnight`, or `auto` as the budget/profile: set `budget_profile` to that string and omit `token_budget`.
- If the user provides a positive integer token budget: set `token_budget` to that integer and omit `budget_profile`.
- If a budget value is anything else: report that the budget must be a positive integer or one of `quick`, `standard`, `deep`, `overnight`, `auto`.

Call the `create_goal` MCP tool with:
- `session_id`: (the system will provide this; if your environment does not auto-supply it, call `get_goal` first to discover it, or ask the user for the session id)
- `objective`: the objective determined above
- Either `token_budget`, `budget_profile`, or neither, following the budget rules above. Never send both.

After the tool returns:
- If success: briefly confirm the goal is active, restate the objective, mention the budget profile or token budget if any, then begin work.
- If `create_goal` fails because a goal already exists in `blocked` or resumable `paused` status, inspect the user's wording. If they explicitly asked to continue, unblock, recover, or resume that existing goal, call `resume_goal` and continue work on that goal. If they explicitly asked to replace, reset, discard, stop, or abandon the existing goal, call `abandon_goal`, then call `create_goal` again with the new objective. If their intent is not explicit, report the error and ask whether to resume or abandon.
- If `create_goal` fails for an active or budget-limited goal, report the error and ask for the appropriate lifecycle action instead of guessing.
- For any other error: report the error to the user verbatim.

From now until the goal is marked complete, after every turn the system will inject a continuation prompt. Keep working toward the objective.

Before marking the goal complete, build and verify a prompt-to-artifact checklist showing every requirement is met. Then dispatch the plugin subagent `claude-goal:goal-evaluator` with the Agent tool (Task is an older alias if Agent is unavailable). Pass the session id, objective, checklist, transcript path if known, and concrete evidence. If it returns `{"verdict":"complete"}`, call `update_goal` with `status: "complete"` and `completed_by: "evaluator"`.

If the evaluator is unavailable, blocked, or explicitly skipped by the user, keep the worker-only fallback: use your own completion audit and call `update_goal` with `status: "complete"` only when the goal is complete. Do not mark complete on partial progress.

If the same blocker repeats across at least three consecutive continuation turns and no meaningful progress is possible without user input or an external-state change, call `update_goal` with `status: "blocked"` and a concise `blocked_reason`. Do not use blocked for work that is merely hard, slow, uncertain, or under-verified.
