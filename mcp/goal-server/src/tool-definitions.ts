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
      description: "Create a new goal. Only call this when the user explicitly invokes /goal-start or explicitly asks in natural language to set up, start, create, or use a goal; do not infer goals from ordinary tasks. If the user does not explicitly request a budget, limiter, token cap, or profile, omit token_budget and budget_profile so the goal is unbounded. Accept either token_budget or budget_profile, never both. Fails if a goal already exists in 'active', 'paused', 'blocked', or 'budget_limited' status; replaces any 'complete' or 'abandoned' prior goal.",
      inputSchema: {
        type: "object",
        required: envSessionId ? ["objective"] : ["session_id", "objective"],
        additionalProperties: false,
        properties: {
          session_id: { type: "string" },
          objective: { type: "string", minLength: 1, maxLength: 4000 },
          token_budget: { type: ["integer", "null"], minimum: 1, description: "Advanced raw token cap. Omit when budget_profile is set." },
          budget_profile: { type: ["string", "null"], enum: ["quick", "standard", "deep", "overnight", "auto", null], description: "Human-friendly run envelope. Use 'auto' only when the user explicitly requests an automatic budget/profile. Omit for an unbounded goal or when token_budget is set." },
        },
      },
    },
    {
      name: "update_goal",
      description: "Update the existing goal. Use this tool only to mark the goal achieved or genuinely blocked. Set status to 'complete' only when the objective has actually been achieved and no required work remains. Set status to 'blocked' only after the same blocker has repeated across at least three consecutive continuation turns and no meaningful progress is possible without user input or an external-state change. Do not mark a goal complete merely because its budget is nearly exhausted or because you are stopping work. The optional 'completed_by' field distinguishes worker self-audit completion from evaluator-confirmed completion: 'evaluator' requires that the claude-goal:goal-evaluator subagent already recorded a 'complete' verdict via record_verdict (the call fails otherwise); worker-only fallback omits it or sends 'self_update'. Evaluator completion may close accounting_error or budget_limited race states; self_update cannot bypass them.",
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
    {
      name: "record_verdict",
      description: "Record the goal-evaluator's completion verdict for the active goal. Reserved for the claude-goal:goal-evaluator subagent — the worker must never call this tool itself; fabricating a verdict defeats the independent-verification audit trail. Verdicts: 'complete' (every requirement verified against real state), 'incomplete' (specific items remain), 'unverifiable' (evaluator could not verify), 'impossible' (the objective is genuinely unachievable in this session — independently confirmed, not just claimed by the worker). A recent 'complete' verdict is required before update_goal with completed_by:'evaluator' succeeds.",
      inputSchema: {
        type: "object",
        required: envSessionId ? ["verdict"] : ["session_id", "verdict"],
        additionalProperties: false,
        properties: {
          session_id: { type: "string" },
          goal_id: { type: ["string", "null"] },
          verdict: { type: "string", enum: ["complete", "incomplete", "unverifiable", "impossible"] },
          reason: { type: ["string", "null"], maxLength: 1000, description: "Short evidence summary (complete) or what remains / could not be verified." },
          evidence: { type: ["array", "null"], items: { type: "string" }, maxItems: 20, description: "Specific verified facts: command exit codes, file contents, test output." },
        },
      },
    },
    {
      name: "update_objective",
      description: "Replace the objective of the current active or budget-limited goal while keeping its budget, token accounting, and history. Use only when the user explicitly changes or refines what the goal should accomplish mid-run; do not use it to narrow the objective so it is easier to complete, and do not use it to mark progress. The next continuation turn picks up the new objective automatically.",
      inputSchema: {
        type: "object",
        required: envSessionId ? ["objective"] : ["session_id", "objective"],
        additionalProperties: false,
        properties: {
          session_id: { type: "string" },
          goal_id: { type: ["string", "null"] },
          objective: { type: "string", minLength: 1, maxLength: 4000 },
        },
      },
    },
    {
      name: "resume_goal",
      description: "Resume the current goal when it is blocked or user/degraded paused. Use this when the user has resolved the blocker or explicitly asks to continue a blocked goal; do not use it to bypass continuation, wall-clock, or token-budget caps.",
      inputSchema: {
        type: "object",
        required: envSessionId ? [] : ["session_id"],
        additionalProperties: false,
        properties: {
          session_id: { type: "string" },
          goal_id: { type: ["string", "null"] },
        },
      },
    },
    {
      name: "abandon_goal",
      description: "Abandon the current active, paused, blocked, or budget-limited goal so the session can stop or start a replacement goal. Use only when the user explicitly asks to stop, abandon, discard, replace, or reset the current goal.",
      inputSchema: {
        type: "object",
        required: envSessionId ? [] : ["session_id"],
        additionalProperties: false,
        properties: {
          session_id: { type: "string" },
          goal_id: { type: ["string", "null"] },
        },
      },
    },
  ];
}
