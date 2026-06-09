import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { ListToolsRequestSchema, CallToolRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { openDb, runMigrations } from "./db.js";
import { GoalsRepo } from "./goals-repo.js";
import { handleGetGoal } from "./tools/get-goal.js";
import { handleCreateGoal } from "./tools/create-goal.js";
import { handleUpdateGoal } from "./tools/update-goal.js";
import { listGoalTools } from "./tool-definitions.js";
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
  { name: "claude-goal", version: "0.2.7" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: listGoalTools(envSessionId),
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
      result = handleCreateGoal(repo, args as { session_id: string; objective: string; token_budget?: number | null; budget_profile?: "quick" | "standard" | "deep" | "overnight" | "auto" | null });
      break;
    case "update_goal":
      result = handleUpdateGoal(repo, args as { session_id: string; goal_id?: string; status: "complete" | "blocked"; completed_by?: "self_update" | "evaluator"; blocked_reason?: string | null });
      break;
    default:
      throw new Error(`unknown tool: ${req.params.name}`);
  }
  return { content: [{ type: "text", text: JSON.stringify(result) }] };
});

await server.connect(new StdioServerTransport());
