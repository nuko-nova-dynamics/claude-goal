export function handleAbandonGoal(repo, args) {
    if (typeof args.session_id !== "string" || args.session_id.length === 0) {
        return { error: "session_id is required" };
    }
    const current = repo.getBySession(args.session_id);
    if (!current || current.status === "complete" || current.status === "abandoned") {
        return { error: "no goal to abandon" };
    }
    try {
        repo.abandon(args.session_id, args.goal_id ?? current.goal_id);
        return { goal: repo.getBySession(args.session_id) };
    }
    catch (e) {
        return { error: e.message };
    }
}
