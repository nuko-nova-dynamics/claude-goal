import type { GoalsRepo, Goal } from "../goals-repo.js";

export function handleResumeGoal(
  repo: GoalsRepo,
  args: { session_id: string; goal_id?: string | null }
): { goal?: Goal; error?: string } {
  if (typeof args.session_id !== "string" || args.session_id.length === 0) {
    return { error: "session_id is required" };
  }
  const current = repo.getBySession(args.session_id);
  if (!current) {
    return { error: "no goal exists" };
  }
  try {
    repo.resume(args.session_id, args.goal_id ?? current.goal_id);
    return { goal: repo.getBySession(args.session_id)! };
  } catch (e) {
    return { error: (e as Error).message };
  }
}
