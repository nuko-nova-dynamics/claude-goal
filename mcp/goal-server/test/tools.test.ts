import { describe, it, expect } from "vitest";
import { openDb, runMigrations } from "../src/db.js";
import { GoalsRepo } from "../src/goals-repo.js";
import { handleGetGoal } from "../src/tools/get-goal.js";
import { handleCreateGoal } from "../src/tools/create-goal.js";
import { handleUpdateGoal } from "../src/tools/update-goal.js";
import { listGoalTools } from "../src/tool-definitions.js";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

function freshRepo() {
  const db = openDb(join(mkdtempSync(join(tmpdir(), "cg-")), "g.db"));
  runMigrations(db);
  return new GoalsRepo(db);
}

describe("tool metadata", () => {
  it("allows explicit natural-language goal starts without silent inference", () => {
    const createGoal = listGoalTools("session-from-env").find(tool => tool.name === "create_goal")!;

    expect(createGoal.description).toContain("explicitly asks in natural language");
    expect(createGoal.description).toContain("do not infer goals from ordinary tasks");
    expect(createGoal.description).toContain("budget_profile='auto' is the smart default");
    expect(createGoal.inputSchema.required).toEqual(["objective"]);
  });

  it("requires session_id when the environment cannot supply one", () => {
    const createGoal = listGoalTools(null).find(tool => tool.name === "create_goal")!;

    expect(createGoal.inputSchema.required).toEqual(["session_id", "objective"]);
  });
});

describe("create_goal tool", () => {
  it("creates and returns the goal", () => {
    const repo = freshRepo();
    const out = handleCreateGoal(repo, { session_id: "s1", objective: "ship it", token_budget: 1000 });
    expect(out.goal!.status).toBe("active");
    expect(out.goal!.objective).toBe("ship it");
    expect(out.goal!.token_budget).toBe(1000);
    expect(out.goal!.budget_source).toBe("tokens");
    expect(out.goal!.budget_profile).toBeNull();
  });

  it("leaves omitted budget unbounded", () => {
    const repo = freshRepo();
    const out = handleCreateGoal(repo, { session_id: "s1", objective: "ship it" });
    expect(out.goal!.token_budget).toBeNull();
    expect(out.goal!.budget_source).toBe("none");
    expect(out.goal!.budget_profile).toBeNull();
  });

  it("accepts explicit budget profile names", () => {
    const repo = freshRepo();
    const out = handleCreateGoal(repo, { session_id: "s1", objective: "ship it", budget_profile: "deep" });
    expect(out.goal!).toMatchObject({
      token_budget: 100000000,
      budget_profile: "deep",
      budget_source: "profile",
      continuations_remaining: 1000,
      max_wall_clock_seconds: 86400,
    });
  });

  it("resolves auto profile from objective", () => {
    const repo = freshRepo();
    const out = handleCreateGoal(repo, {
      session_id: "s1",
      objective: "run a repo-wide migration and verify tests",
      budget_profile: "auto",
    });
    expect(out.goal!).toMatchObject({
      token_budget: 100000000,
      budget_profile: "deep",
      budget_source: "auto",
    });
  });

  it("rejects invalid budget_profile values", () => {
    const repo = freshRepo();
    const out = handleCreateGoal(repo, { session_id: "s1", objective: "ship it", budget_profile: "huge" as never });
    expect(out.error).toMatch(/budget_profile must be one of/);
  });

  it("rejects token_budget and budget_profile together", () => {
    const repo = freshRepo();
    const out = handleCreateGoal(repo, { session_id: "s1", objective: "ship it", token_budget: 1000, budget_profile: "quick" });
    expect(out.error).toMatch(/mutually exclusive/);
  });

  it("rejects malformed raw token budgets", () => {
    const repo = freshRepo();
    expect(handleCreateGoal(repo, { session_id: "s1", objective: "ship it", token_budget: "1000" as never }).error).toMatch(/positive integer/);
    expect(handleCreateGoal(repo, { session_id: "s2", objective: "ship it", token_budget: 1.5 }).error).toMatch(/positive integer/);
    expect(handleCreateGoal(repo, { session_id: "s3", objective: "ship it", token_budget: 0 }).error).toMatch(/positive integer/);
  });

  it("rejects missing session_id", () => {
    const repo = freshRepo();
    expect(handleCreateGoal(repo, { session_id: "", objective: "ship it", token_budget: null }).error).toMatch(/session_id is required/);
    expect(handleCreateGoal(repo, { session_id: 123 as never, objective: "ship it", token_budget: null }).error).toMatch(/session_id is required/);
  });

  it("returns structured error when goal exists", () => {
    const repo = freshRepo();
    handleCreateGoal(repo, { session_id: "s1", objective: "first", token_budget: null });
    const out = handleCreateGoal(repo, { session_id: "s1", objective: "second", token_budget: null });
    expect(out.error).toMatch(/already exists/);
  });

  it("rejects empty objective", () => {
    const repo = freshRepo();
    const out = handleCreateGoal(repo, { session_id: "s1", objective: "", token_budget: null });
    expect(out.error).toMatch(/objective is required/);
  });

  it("rejects whitespace-only objective", () => {
    const repo = freshRepo();
    const out = handleCreateGoal(repo, { session_id: "s1", objective: "   ", token_budget: null });
    expect(out.error).toMatch(/objective is required/);
  });

  it("rejects non-string objective without throwing", () => {
    const repo = freshRepo();
    const out = handleCreateGoal(repo, { session_id: "s1", objective: 123 as never, token_budget: null });
    expect(out.error).toMatch(/objective is required/);
  });

  it("rejects objective over 4000 characters", () => {
    const repo = freshRepo();
    const tooLong = "x".repeat(4001);
    const out = handleCreateGoal(repo, { session_id: "s1", objective: tooLong, token_budget: null });
    expect(out.error).toMatch(/4000 characters/);
    expect(out.error).toMatch(/got 4001/);
  });

  it("accepts objective at the 4000-character boundary", () => {
    const repo = freshRepo();
    const exactly = "x".repeat(4000);
    const out = handleCreateGoal(repo, { session_id: "s1", objective: exactly, token_budget: null });
    expect(out.goal!.status).toBe("active");
  });
});

describe("get_goal tool", () => {
  it("returns null for unknown session", () => {
    const repo = freshRepo();
    expect(handleGetGoal(repo, { session_id: "absent" }).goal).toBeNull();
  });
});

describe("update_goal tool", () => {
  it("rejects status other than complete", () => {
    const repo = freshRepo();
    handleCreateGoal(repo, { session_id: "s1", objective: "x", token_budget: null });
    const out = handleUpdateGoal(repo, { session_id: "s1", status: "paused" as never });
    expect(out.error).toMatch(/only.*complete.*blocked/i);
  });

  it("marks complete on valid call", () => {
    const repo = freshRepo();
    handleCreateGoal(repo, { session_id: "s1", objective: "x", token_budget: null });
    const out = handleUpdateGoal(repo, { session_id: "s1", status: "complete" });
    expect(out.goal!.status).toBe("complete");
  });

  it("records goal_completed_by_self_update event when completed_by omitted", () => {
    const repo = freshRepo();
    handleCreateGoal(repo, { session_id: "s1", objective: "x", token_budget: null });
    handleUpdateGoal(repo, { session_id: "s1", status: "complete" });
    const events = repo["db"]
      .prepare("SELECT event_type FROM goal_events WHERE session_id='s1' ORDER BY id DESC LIMIT 1")
      .get() as { event_type: string };
    expect(events.event_type).toBe("goal_completed_by_self_update");
  });

  it("records goal_completed_by_evaluator event when completed_by='evaluator'", () => {
    const repo = freshRepo();
    handleCreateGoal(repo, { session_id: "s1", objective: "x", token_budget: null });
    handleUpdateGoal(repo, { session_id: "s1", status: "complete", completed_by: "evaluator" });
    const events = repo["db"]
      .prepare("SELECT event_type FROM goal_events WHERE session_id='s1' ORDER BY id DESC LIMIT 1")
      .get() as { event_type: string };
    expect(events.event_type).toBe("goal_completed_by_evaluator");
  });

  it("allows evaluator completion from accounting_error pause", () => {
    const repo = freshRepo();
    handleCreateGoal(repo, { session_id: "s1", objective: "x", token_budget: null });
    const goal = repo.getBySession("s1")!;
    repo.pause("s1", goal.goal_id, "accounting_error");

    const out = handleUpdateGoal(repo, { session_id: "s1", status: "complete", completed_by: "evaluator" });

    expect(out.goal!.status).toBe("complete");
    expect(out.goal!.paused_reason).toBeNull();
  });

  it("rejects self-update completion from accounting_error pause", () => {
    const repo = freshRepo();
    handleCreateGoal(repo, { session_id: "s1", objective: "x", token_budget: null });
    const goal = repo.getBySession("s1")!;
    repo.pause("s1", goal.goal_id, "accounting_error");

    const out = handleUpdateGoal(repo, { session_id: "s1", status: "complete" });

    expect(out.error).toMatch(/accounting_error.*evaluator/);
    expect(repo.getBySession("s1")!.status).toBe("paused");
  });

  it("rejects unknown completed_by values", () => {
    const repo = freshRepo();
    handleCreateGoal(repo, { session_id: "s1", objective: "x", token_budget: null });
    const out = handleUpdateGoal(repo, { session_id: "s1", status: "complete", completed_by: "bogus" as never });
    expect(out.error).toMatch(/completed_by must be/);
  });

  it("does not allow budget_limited goals to be overwritten as complete", () => {
    const repo = freshRepo();
    handleCreateGoal(repo, { session_id: "s1", objective: "x", token_budget: 1000 });
    repo.pause("s1", repo.getBySession("s1")!.goal_id, "degraded");
    repo.resume("s1", repo.getBySession("s1")!.goal_id);
    repo.testHelper_setStatus("s1", "budget_limited");

    const out = handleUpdateGoal(repo, { session_id: "s1", status: "complete" });

    expect(out.error).toMatch(/cannot mark complete from status 'budget_limited'/);
    expect(repo.getBySession("s1")!.status).toBe("budget_limited");
  });

  it("marks blocked on valid call and records reason", () => {
    const repo = freshRepo();
    handleCreateGoal(repo, { session_id: "s1", objective: "x", token_budget: null });
    const out = handleUpdateGoal(repo, {
      session_id: "s1",
      status: "blocked",
      blocked_reason: "requires credentials from user",
    });

    expect(out.goal!.status).toBe("blocked");
    const event = repo["db"]
      .prepare("SELECT event_type, payload_json FROM goal_events WHERE session_id='s1' ORDER BY id DESC LIMIT 1")
      .get() as { event_type: string; payload_json: string };
    expect(event.event_type).toBe("goal_blocked");
    expect(JSON.parse(event.payload_json).reason).toBe("requires credentials from user");
  });

  it("rejects completed_by when status is blocked", () => {
    const repo = freshRepo();
    handleCreateGoal(repo, { session_id: "s1", objective: "x", token_budget: null });
    const out = handleUpdateGoal(repo, {
      session_id: "s1",
      status: "blocked",
      completed_by: "evaluator",
    });

    expect(out.error).toMatch(/completed_by.*only valid.*complete/);
    expect(repo.getBySession("s1")!.status).toBe("active");
  });

  it("rejects overlong blocked_reason", () => {
    const repo = freshRepo();
    handleCreateGoal(repo, { session_id: "s1", objective: "x", token_budget: null });
    const out = handleUpdateGoal(repo, {
      session_id: "s1",
      status: "blocked",
      blocked_reason: "x".repeat(1001),
    });

    expect(out.error).toMatch(/1000 characters/);
    expect(repo.getBySession("s1")!.status).toBe("active");
  });
});
