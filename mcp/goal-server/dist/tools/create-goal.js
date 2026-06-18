import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { isBudgetProfileInput } from "../budget-profiles.js";
const OBJECTIVE_MAX = 4000;
function settingsHaveHooksDisabled() {
    const candidates = [
        join(homedir(), ".claude", "settings.json"),
        join(homedir(), ".claude", "settings.local.json"),
        join(process.cwd(), ".claude", "settings.json"),
        join(process.cwd(), ".claude", "settings.local.json"),
    ];
    for (const file of candidates) {
        if (!existsSync(file))
            continue;
        try {
            const parsed = JSON.parse(readFileSync(file, "utf8"));
            if (parsed?.disableAllHooks === true)
                return file;
        }
        catch {
            // unreadable / malformed → ignore, don't block goal creation on parse errors
        }
    }
    return null;
}
export function handleCreateGoal(repo, args) {
    const disabledIn = settingsHaveHooksDisabled();
    if (disabledIn) {
        return {
            error: `cannot create goal: disableAllHooks=true is set in ${disabledIn}. The claude-goal continuation loop depends on Stop, PostToolBatch, and SessionStart hooks. Remove disableAllHooks (or set to false) and restart claude.`,
        };
    }
    if (typeof args.session_id !== "string" || args.session_id.length === 0) {
        return { error: "session_id is required" };
    }
    if (typeof args.objective !== "string" || args.objective.trim().length === 0) {
        return { error: "objective is required" };
    }
    if (args.objective.length > OBJECTIVE_MAX) {
        return {
            error: `objective exceeds ${OBJECTIVE_MAX} characters (got ${args.objective.length}). Trim the objective or split into smaller goals.`,
        };
    }
    const tokenBudget = args.token_budget ?? null;
    const budgetProfile = args.budget_profile ?? null;
    if (tokenBudget !== null && (!Number.isInteger(tokenBudget) || tokenBudget <= 0)) {
        return { error: "token_budget must be a positive integer" };
    }
    if (tokenBudget !== null && budgetProfile !== null) {
        return { error: "token_budget and budget_profile are mutually exclusive" };
    }
    if (budgetProfile !== null && !isBudgetProfileInput(budgetProfile)) {
        return { error: `budget_profile must be one of quick, standard, deep, overnight, auto; got '${budgetProfile}'` };
    }
    try {
        const goal = repo.create({
            session_id: args.session_id,
            objective: args.objective,
            token_budget: tokenBudget,
            budget_profile: budgetProfile,
        });
        return { goal };
    }
    catch (e) {
        return { error: e.message };
    }
}
