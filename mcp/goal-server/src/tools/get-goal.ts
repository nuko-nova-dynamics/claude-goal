import type { GoalsRepo, Goal } from "../goals-repo.js";

export function handleGetGoal(repo: GoalsRepo, args: { session_id: string }): { goal: Goal | null } {
  return { goal: repo.getBySession(args.session_id) };
}
