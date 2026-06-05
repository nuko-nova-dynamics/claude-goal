import { describe, it, expect, beforeEach } from "vitest";
import { openDb, runMigrations } from "../src/db.js";
import { GoalsRepo } from "../src/goals-repo.js";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

function freshRepo() {
  const dir = mkdtempSync(join(tmpdir(), "claude-goal-test-"));
  const db = openDb(join(dir, "goals.db"));
  runMigrations(db);
  return new GoalsRepo(db);
}

describe("GoalsRepo.getBySession", () => {
  it("returns null for unknown session", () => {
    const repo = freshRepo();
    expect(repo.getBySession("abc")).toBeNull();
  });
});

describe("GoalsRepo.create", () => {
  it("creates a new goal in active status", () => {
    const repo = freshRepo();
    const goal = repo.create({ session_id: "s1", objective: "ship the auth migration", token_budget: 50000 });
    expect(goal.status).toBe("active");
    expect(goal.tokens_used).toBe(0);
    expect(goal.subagent_tokens).toBe(0);
    expect(goal.continuations_remaining).toBe(50);
    expect(goal.resume_at_ms).toBeGreaterThan(0);
    expect(goal.goal_id).toMatch(/^[0-9a-f-]{36}$/);
  });

  it("rejects creation when active goal exists", () => {
    const repo = freshRepo();
    repo.create({ session_id: "s1", objective: "first", token_budget: null });
    expect(() => repo.create({ session_id: "s1", objective: "second", token_budget: null })).toThrow(/already exists.*active/);
  });

  it("rejects creation when paused goal exists", () => {
    const repo = freshRepo();
    const first = repo.create({ session_id: "s1", objective: "first", token_budget: null });
    repo.pause("s1", first.goal_id, "user");
    expect(() => repo.create({ session_id: "s1", objective: "second", token_budget: null })).toThrow(/already exists.*paused/);
  });

  it("rejects creation when blocked goal exists", () => {
    const repo = freshRepo();
    const first = repo.create({ session_id: "s1", objective: "first", token_budget: null });
    repo.markBlocked("s1", first.goal_id, "waiting on user input");
    expect(() => repo.create({ session_id: "s1", objective: "second", token_budget: null })).toThrow(/already exists.*blocked/);
  });

  it("replaces a complete goal with goal_replaced event", () => {
    const repo = freshRepo();
    const first = repo.create({ session_id: "s1", objective: "first", token_budget: null });
    repo.markComplete("s1", first.goal_id);
    const second = repo.create({ session_id: "s1", objective: "second", token_budget: null });
    expect(second.goal_id).not.toBe(first.goal_id);
    expect(second.status).toBe("active");
    expect(second.subagent_tokens).toBe(0);

    const events = repo.listEvents("s1");
    expect(events.find(e => e.event_type === "goal_replaced")).toBeTruthy();
  });

  it("replacement resets continuation and wall-clock caps", () => {
    const repo = freshRepo();
    const first = repo.create({ session_id: "s1", objective: "first", token_budget: null });
    repo["db"]
      .prepare("UPDATE goals SET continuations_remaining = 3, max_wall_clock_seconds = 999999 WHERE session_id = 's1'")
      .run();
    repo.markComplete("s1", first.goal_id);

    const second = repo.create({ session_id: "s1", objective: "second", token_budget: null });

    expect(second.continuations_remaining).toBe(50);
    expect(second.max_wall_clock_seconds).toBe(14400);
  });

  it("rejects empty objective", () => {
    const repo = freshRepo();
    expect(() => repo.create({ session_id: "s1", objective: "", token_budget: null })).toThrow();
  });

  it("rejects objective > 4000 chars", () => {
    const repo = freshRepo();
    expect(() => repo.create({ session_id: "s1", objective: "a".repeat(4001), token_budget: null })).toThrow();
  });
});

describe("GoalsRepo.markComplete", () => {
  it("transitions active → complete and flushes wall-clock", () => {
    const repo = freshRepo();
    const g = repo.create({ session_id: "s1", objective: "x", token_budget: null });
    // simulate 2s elapsed
    repo.testHelper_setResumeAt(g.session_id, Date.now() - 2000);
    repo.markComplete("s1", g.goal_id);
    const after = repo.getBySession("s1")!;
    expect(after.status).toBe("complete");
    expect(after.resume_at_ms).toBeNull();
    expect(after.time_used_seconds).toBeGreaterThanOrEqual(2);
  });

  it("rejects completing an abandoned goal", () => {
    const repo = freshRepo();
    const g = repo.create({ session_id: "s1", objective: "x", token_budget: null });
    repo.abandon("s1", g.goal_id);
    expect(() => repo.markComplete("s1", g.goal_id)).toThrow(/cannot.*complete.*status/);
  });
});

describe("GoalsRepo.markBlocked", () => {
  it("transitions active to blocked and records reason", () => {
    const repo = freshRepo();
    const g = repo.create({ session_id: "s1", objective: "x", token_budget: null });
    repo.testHelper_setResumeAt(g.session_id, Date.now() - 2000);
    repo.markBlocked("s1", g.goal_id, "external approval required");

    const after = repo.getBySession("s1")!;
    expect(after.status).toBe("blocked");
    expect(after.resume_at_ms).toBeNull();
    expect(after.time_used_seconds).toBeGreaterThanOrEqual(2);

    const event = repo["db"]
      .prepare("SELECT event_type, status_before, status_after, payload_json FROM goal_events WHERE session_id='s1' ORDER BY id DESC LIMIT 1")
      .get() as { event_type: string; status_before: string; status_after: string; payload_json: string };
    expect(event.event_type).toBe("goal_blocked");
    expect(event.status_before).toBe("active");
    expect(event.status_after).toBe("blocked");
    expect(JSON.parse(event.payload_json).reason).toBe("external approval required");
  });

  it("rejects blocking a completed goal", () => {
    const repo = freshRepo();
    const g = repo.create({ session_id: "s1", objective: "x", token_budget: null });
    repo.markComplete("s1", g.goal_id);
    expect(() => repo.markBlocked("s1", g.goal_id, "late blocker")).toThrow(/cannot mark blocked from status 'complete'/);
  });
});

describe("GoalsRepo.pause/resume", () => {
  it("pause(user) flushes wall-clock and clears resume_at", () => {
    const repo = freshRepo();
    const g = repo.create({ session_id: "s1", objective: "x", token_budget: null });
    repo.testHelper_setResumeAt("s1", Date.now() - 5000);
    repo.pause("s1", g.goal_id, "user");
    const after = repo.getBySession("s1")!;
    expect(after.status).toBe("paused");
    expect(after.paused_reason).toBe("user");
    expect(after.resume_at_ms).toBeNull();
    expect(after.time_used_seconds).toBeGreaterThanOrEqual(5);
  });

  it("resume(user-paused) sets resume_at and active", () => {
    const repo = freshRepo();
    const g = repo.create({ session_id: "s1", objective: "x", token_budget: null });
    repo.pause("s1", g.goal_id, "user");
    repo.resume("s1", g.goal_id);
    const after = repo.getBySession("s1")!;
    expect(after.status).toBe("active");
    expect(after.paused_reason).toBeNull();
    expect(after.resume_at_ms).toBeGreaterThan(0);
  });

  it("resume rejects cap-paused goals", () => {
    const repo = freshRepo();
    const g = repo.create({ session_id: "s1", objective: "x", token_budget: null });
    repo.pause("s1", g.goal_id, "continuation_cap");
    expect(() => repo.resume("s1", g.goal_id)).toThrow(/use \/goal-extend/i);
  });

  it("resume restarts a blocked goal", () => {
    const repo = freshRepo();
    const g = repo.create({ session_id: "s1", objective: "x", token_budget: null });
    repo.markBlocked("s1", g.goal_id, "needs credentials");
    repo.resume("s1", g.goal_id);

    const after = repo.getBySession("s1")!;
    expect(after.status).toBe("active");
    expect(after.resume_at_ms).toBeGreaterThan(0);

    const event = repo["db"]
      .prepare("SELECT status_before, status_after FROM goal_events WHERE event_type='goal_resumed' ORDER BY id DESC LIMIT 1")
      .get() as { status_before: string; status_after: string };
    expect(event.status_before).toBe("blocked");
    expect(event.status_after).toBe("active");
  });
});
