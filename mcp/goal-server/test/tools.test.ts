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
});
