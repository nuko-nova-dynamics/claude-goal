import { describe, it, expect } from "vitest";
import { openDb, runMigrations } from "../src/db.js";
import { GoalsRepo } from "../src/goals-repo.js";
import { handleGetGoal } from "../src/tools/get-goal.js";
import { handleCreateGoal } from "../src/tools/create-goal.js";
import { handleUpdateGoal } from "../src/tools/update-goal.js";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

function freshRepo() {
  const db = openDb(join(mkdtempSync(join(tmpdir(), "cg-")), "g.db"));
  runMigrations(db);
  return new GoalsRepo(db);
}

describe("create_goal tool", () => {
  it("creates and returns the goal", () => {
    const repo = freshRepo();
    const out = handleCreateGoal(repo, { session_id: "s1", objective: "ship it", token_budget: 1000 });
    expect(out.goal!.status).toBe("active");
    expect(out.goal!.objective).toBe("ship it");
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
    expect(out.error).toMatch(/only.*complete/i);
  });

  it("marks complete on valid call", () => {
    const repo = freshRepo();
    handleCreateGoal(repo, { session_id: "s1", objective: "x", token_budget: null });
    const out = handleUpdateGoal(repo, { session_id: "s1", status: "complete" });
    expect(out.goal!.status).toBe("complete");
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
});
