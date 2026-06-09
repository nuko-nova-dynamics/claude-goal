export function handleUpdateGoal(repo, args) {
    if (args.status !== "complete" && args.status !== "blocked") {
        return { error: "update_goal can only set status to 'complete' or 'blocked'; use slash commands for pause/resume/abandon" };
    }
    if (args.status === "blocked") {
        if (args.completed_by) {
            return { error: "completed_by is only valid when status is 'complete'" };
        }
        if (args.blocked_reason && args.blocked_reason.length > 1000) {
            return { error: `blocked_reason exceeds 1000 characters (got ${args.blocked_reason.length})` };
        }
        try {
            repo.markBlocked(args.session_id, args.goal_id ?? undefined, args.blocked_reason ?? null);
            return { goal: repo.getBySession(args.session_id) };
        }
        catch (e) {
            return { error: e.message };
        }
    }
    const completedBy = args.completed_by ?? "self_update";
    if (completedBy !== "self_update" && completedBy !== "evaluator") {
        return { error: `completed_by must be 'self_update' or 'evaluator', got '${completedBy}'` };
    }
    try {
        repo.markComplete(args.session_id, args.goal_id ?? undefined, completedBy);
        return { goal: repo.getBySession(args.session_id) };
    }
    catch (e) {
        return { error: e.message };
    }
}
