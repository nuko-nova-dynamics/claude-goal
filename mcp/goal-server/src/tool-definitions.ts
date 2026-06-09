export function listGoalTools(envSessionId: string | null) {
  return [
    {
      name: "get_goal",
      description: "Get the current goal for this session, including status, budgets, token usage, and remaining budget.",
      inputSchema: {
        type: "object",
        required: envSessionId ? [] : ["session_id"],
        additionalProperties: false,
        properties: { session_id: { type: "string" } },
      },
    },
    {
      name: "create_goal",
      description: "Create a new goal. Only call this when the user explicitly invokes /goal-start or explicitly asks in natural language to set up, start, create, or use a goal; do not infer goals from ordinary tasks. For explicit natural-language goal requests without a user-specified budget, budget_profile='auto' is the smart default. Accept either token_budget or budget_profile, never both. Fails if a goal already exists in 'active', 'paused', 'blocked', or 'budget_limited' status; replaces any 'complete' or 'abandoned' prior goal.",
      inputSchema: {
        type: "object",
        required: envSessionId ? ["objective"] : ["session_id", "objective"],
        additionalProperties: false,
        properties: {
          session_id: { type: "string" },
          objective: { type: "string", minLength: 1, maxLength: 4000 },
          token_budget: { type: ["integer", "null"], minimum: 1, description: "Advanced raw token cap. Omit when budget_profile is set." },
          budget_profile: { type: ["string", "null"], enum: ["quick", "standard", "deep", "overnight", "auto", null], description: "Human-friendly run envelope. Use 'auto' for explicit natural-language goal requests without a user-specified budget. Omit for an unbounded goal or when token_budget is set." },
        },
      },
    },
    {
      name: "update_goal",
      description: "Update the existing goal. Use this tool only to mark the goal achieved or genuinely blocked. Set status to 'complete' only when the objective has actually been achieved and no required work remains. Set status to 'blocked' only after the same blocker has repeated across at least three consecutive continuation turns and no meaningful progress is possible without user input or an external-state change. Do not mark a goal complete merely because its budget is nearly exhausted or because you are stopping work. The optional 'completed_by' field distinguishes worker self-audit completion from evaluator-confirmed completion (after the claude-goal:goal-evaluator subagent returns verdict 'complete', send 'evaluator'; worker-only fallback omits it or sends 'self_update').",
      inputSchema: {
        type: "object",
        required: envSessionId ? ["status"] : ["session_id", "status"],
        additionalProperties: false,
        properties: {
          session_id: { type: "string" },
          goal_id: { type: ["string", "null"] },
          status: { type: "string", enum: ["complete", "blocked"] },
          completed_by: { type: "string", enum: ["self_update", "evaluator"] },
          blocked_reason: { type: ["string", "null"], maxLength: 1000 },
        },
      },
    },
  ];
}
