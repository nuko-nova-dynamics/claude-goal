export function handleGetGoal(repo, args) {
    return { goal: repo.getBySession(args.session_id) };
}
