import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { ListToolsRequestSchema, CallToolRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { openDb, runMigrations } from "./db.js";
import { GoalsRepo } from "./goals-repo.js";
import { handleGetGoal } from "./tools/get-goal.js";
import { handleCreateGoal } from "./tools/create-goal.js";
import { handleUpdateGoal } from "./tools/update-goal.js";
import { mkdirSync } from "node:fs";
import { join } from "node:path";

const dataDir = process.env.CLAUDE_PLUGIN_DATA ?? join(process.env.HOME ?? "/tmp", ".claude/plugins/data/claude-goal");
mkdirSync(dataDir, { recursive: true });
const db = openDb(join(dataDir, "goals.db"));
runMigrations(db);
const repo = new GoalsRepo(db);

// Branch A defaulting: if env var inheritance works, tools default session_id from env
const envSessionId = process.env.CLAUDE_SESSION_ID ?? process.env.CLAUDE_CODE_SESSION_ID ?? null;

function ensureSessionId(args: Record<string, unknown>): string {
  const sid = (args.session_id as string | undefined) ?? envSessionId;
  if (!sid) throw new Error("session_id required (and no CLAUDE_SESSION_ID env var)");
  return sid;
}

const server = new Server(
  { name: "claude-goal", version: "0.1.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
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
      description: "Create a new goal. Only call this when the user explicitly invokes /goal-start — do not infer goals from ordinary tasks. Fails if a goal already exists in 'active' or 'budget_limited' status; replaces any 'complete', 'paused', or 'abandoned' prior goal.",
      inputSchema: {
        type: "object",
        required: envSessionId ? ["objective"] : ["session_id", "objective"],
        additionalProperties: false,
        properties: {
          session_id: { type: "string" },
          objective: { type: "string", minLength: 1, maxLength: 4000 },
          token_budget: { type: ["integer", "null"], minimum: 1 },
        },
      },
    },
    {
      name: "update_goal",
      description: "Update the existing goal. Use this tool only to mark the goal achieved. Set status to 'complete' only when the objective has actually been achieved and no required work remains. Do not mark a goal complete merely because its budget is nearly exhausted or because you are stopping work. The optional 'completed_by' field distinguishes worker self-audit completion from evaluator-confirmed completion (after the claude-goal:goal-evaluator subagent returns verdict 'complete', send 'evaluator'; worker-only fallback omits it or sends 'self_update').",
      inputSchema: {
        type: "object",
        required: envSessionId ? ["status"] : ["session_id", "status"],
        additionalProperties: false,
        properties: {
          session_id: { type: "string" },
          goal_id: { type: ["string", "null"] },
          status: { type: "string", enum: ["complete"] },
          completed_by: { type: "string", enum: ["self_update", "evaluator"] },
        },
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const rawArgs = req.params.arguments as Record<string, unknown>;
  const session_id = ensureSessionId(rawArgs);
  const args = { ...rawArgs, session_id };
  let result: unknown;
  switch (req.params.name) {
    case "get_goal":
      result = handleGetGoal(repo, args as { session_id: string });
      break;
    case "create_goal":
      result = handleCreateGoal(repo, args as { session_id: string; objective: string; token_budget: number | null });
      break;
    case "update_goal":
      result = handleUpdateGoal(repo, args as { session_id: string; goal_id?: string; status: "complete"; completed_by?: "self_update" | "evaluator" });
      break;
    default:
      throw new Error(`unknown tool: ${req.params.name}`);
  }
  return { content: [{ type: "text", text: JSON.stringify(result) }] };
});

await server.connect(new StdioServerTransport());
