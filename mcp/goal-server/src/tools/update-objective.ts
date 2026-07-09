import type { GoalsRepo, Goal } from "../goals-repo.js";

export function handleUpdateObjective(
  repo: GoalsRepo,
  args: { session_id: string; goal_id?: string | null; objective: string }
): { goal?: Goal; error?: string } {
  if (typeof args.session_id !== "string" || args.session_id.length === 0) {
    return { error: "session_id is required" };
  }
  if (typeof args.objective !== "string" || args.objective.trim().length === 0) {
    return { error: "objective is required" };
  }
  if (args.objective.length > 4000) {
    return { error: `objective exceeds 4000 characters (got ${args.objective.length})` };
  }
  try {
    repo.updateObjective(args.session_id, args.goal_id ?? undefined, args.objective);
    return { goal: repo.getBySession(args.session_id)! };
  } catch (e) {
    return { error: (e as Error).message };
  }
}
