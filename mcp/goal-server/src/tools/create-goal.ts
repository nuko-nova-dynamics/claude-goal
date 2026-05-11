import type { GoalsRepo, Goal } from "../goals-repo.js";

export function handleCreateGoal(
  repo: GoalsRepo,
  args: { session_id: string; objective: string; token_budget: number | null }
): { goal?: Goal; error?: string } {
  try {
    const goal = repo.create({
      session_id: args.session_id,
      objective: args.objective,
      token_budget: args.token_budget,
    });
    return { goal };
  } catch (e) {
    return { error: (e as Error).message };
  }
}
