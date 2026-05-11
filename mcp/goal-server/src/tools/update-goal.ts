import type { GoalsRepo, Goal } from "../goals-repo.js";

export function handleUpdateGoal(
  repo: GoalsRepo,
  args: { session_id: string; goal_id?: string | null; status: "complete" }
): { goal?: Goal; error?: string } {
  if (args.status !== "complete") {
    return { error: "update_goal can only set status to 'complete'; use slash commands for pause/abandon" };
  }
  try {
    repo.markComplete(args.session_id, args.goal_id ?? undefined);
    return { goal: repo.getBySession(args.session_id)! };
  } catch (e) {
    return { error: (e as Error).message };
  }
}
