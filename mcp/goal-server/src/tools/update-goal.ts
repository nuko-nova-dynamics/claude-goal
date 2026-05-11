import type { GoalsRepo, Goal } from "../goals-repo.js";

export function handleUpdateGoal(
  repo: GoalsRepo,
  args: { session_id: string; goal_id?: string | null; status: "complete"; completed_by?: "self_update" | "evaluator" }
): { goal?: Goal; error?: string } {
  if (args.status !== "complete") {
    return { error: "update_goal can only set status to 'complete'; use slash commands for pause/abandon" };
  }
  const completedBy = args.completed_by ?? "self_update";
  if (completedBy !== "self_update" && completedBy !== "evaluator") {
    return { error: `completed_by must be 'self_update' or 'evaluator', got '${completedBy}'` };
  }
  try {
    repo.markComplete(args.session_id, args.goal_id ?? undefined, completedBy);
    return { goal: repo.getBySession(args.session_id)! };
  } catch (e) {
    return { error: (e as Error).message };
  }
}
