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
function ensureSessionId(args) {
    const sid = args.session_id ?? envSessionId;
    if (!sid)
        throw new Error("session_id required (and no CLAUDE_SESSION_ID env var)");
    return sid;
}
const server = new Server({ name: "claude-goal", version: "0.2.7" }, { capabilities: { tools: {} } });
server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: listGoalTools(envSessionId),
}));
server.setRequestHandler(CallToolRequestSchema, async (req) => {
    const rawArgs = req.params.arguments;
    const session_id = ensureSessionId(rawArgs);
    const args = { ...rawArgs, session_id };
    let result;
    switch (req.params.name) {
        case "get_goal":
            result = handleGetGoal(repo, args);
            break;
        case "create_goal":
            result = handleCreateGoal(repo, args);
            break;
        case "update_goal":
            result = handleUpdateGoal(repo, args);
            break;
        default:
            throw new Error(`unknown tool: ${req.params.name}`);
    }
    return { content: [{ type: "text", text: JSON.stringify(result) }] };
});
await server.connect(new StdioServerTransport());
