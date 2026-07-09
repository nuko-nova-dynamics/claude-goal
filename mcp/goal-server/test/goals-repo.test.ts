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
    const goal = repo.create({ session_id: "s1", objective: "ship the auth migration", token_budget: 50000, budget_profile: null });
    expect(goal.status).toBe("active");
    expect(goal.tokens_used).toBe(0);
    expect(goal.subagent_tokens).toBe(0);
    expect(goal.continuations_remaining).toBe(1000000);
    expect(goal.max_wall_clock_seconds).toBe(315360000);
    expect(goal.budget_profile).toBeNull();
    expect(goal.budget_source).toBe("tokens");
    expect(goal.resume_at_ms).toBeGreaterThan(0);
    expect(goal.goal_id).toMatch(/^[0-9a-f-]{36}$/);
  });

  it("creates an unbounded goal when no budget is provided", () => {
    const repo = freshRepo();
    const goal = repo.create({ session_id: "s1", objective: "explore", token_budget: null, budget_profile: null });
    expect(goal.token_budget).toBeNull();
    expect(goal.budget_profile).toBeNull();
    expect(goal.budget_source).toBe("none");
    expect(goal.continuations_remaining).toBe(1000000);
    expect(goal.max_wall_clock_seconds).toBe(315360000);
  });

  it("applies explicit budget profiles as full run envelopes", () => {
    const repo = freshRepo();
    const quick = repo.create({ session_id: "quick", objective: "inspect one file", token_budget: null, budget_profile: "quick" });
    const standard = repo.create({ session_id: "standard", objective: "add a small feature with tests", token_budget: null, budget_profile: "standard" });
    const deep = repo.create({ session_id: "deep", objective: "repo-wide migration", token_budget: null, budget_profile: "deep" });
    const overnight = repo.create({ session_id: "overnight", objective: "run overnight", token_budget: null, budget_profile: "overnight" });

    expect(quick).toMatchObject({ token_budget: 2000000, budget_profile: "quick", budget_source: "profile", continuations_remaining: 50, max_wall_clock_seconds: 7200 });
    expect(standard).toMatchObject({ token_budget: 10000000, budget_profile: "standard", budget_source: "profile", continuations_remaining: 200, max_wall_clock_seconds: 28800 });
    expect(deep).toMatchObject({ token_budget: 100000000, budget_profile: "deep", budget_source: "profile", continuations_remaining: 1000, max_wall_clock_seconds: 86400 });
    expect(overnight).toMatchObject({ token_budget: 1000000000, budget_profile: "overnight", budget_source: "profile", continuations_remaining: 5000, max_wall_clock_seconds: 259200 });
  });

  it("resolves auto profiles deterministically", () => {
    const repo = freshRepo();
    const overnight = repo.create({ session_id: "s-overnight", objective: "keep working overnight until the migration is verified", token_budget: null, budget_profile: "auto" });
    const deep = repo.create({ session_id: "s-deep", objective: "repo wide redesign with integrations across many named files", token_budget: null, budget_profile: "auto" });
    const standard = repo.create({ session_id: "s-standard", objective: "implement a bounded bug fix with tests", token_budget: null, budget_profile: "auto" });
    const quick = repo.create({ session_id: "s-quick", objective: "inspect config", token_budget: null, budget_profile: "auto" });

    expect(overnight).toMatchObject({ budget_profile: "overnight", budget_source: "auto" });
    expect(deep).toMatchObject({ budget_profile: "deep", budget_source: "auto" });
    expect(standard).toMatchObject({ budget_profile: "standard", budget_source: "auto" });
    expect(quick).toMatchObject({ budget_profile: "quick", budget_source: "auto" });
  });

  it("rejects token budget and budget profile together", () => {
    const repo = freshRepo();
    expect(() => repo.create({ session_id: "s1", objective: "x", token_budget: 1000, budget_profile: "quick" })).toThrow(/mutually exclusive/);
  });

  it("rejects malformed raw token budgets", () => {
    const repo = freshRepo();
    expect(() => repo.create({ session_id: "s1", objective: "x", token_budget: "1000" as never, budget_profile: null })).toThrow(/positive integer/);
    expect(() => repo.create({ session_id: "s2", objective: "x", token_budget: 1.5, budget_profile: null })).toThrow(/positive integer/);
    expect(() => repo.create({ session_id: "s3", objective: "x", token_budget: 0, budget_profile: null })).toThrow(/positive integer/);
  });

  it("rejects malformed create input fields before writing", () => {
    const repo = freshRepo();
    expect(() => repo.create({ session_id: "", objective: "x", token_budget: null, budget_profile: null })).toThrow(/session_id is required/);
    expect(() => repo.create({ session_id: "s1", objective: 123 as never, token_budget: null, budget_profile: null })).toThrow(/objective must be 1-4000/);
    expect(() => repo.create({ session_id: "s2", objective: "   ", token_budget: null, budget_profile: null })).toThrow(/objective must be 1-4000/);
    expect(() => repo.create({ session_id: "s3", objective: "x", token_budget: null, budget_profile: "huge" as never })).toThrow(/budget_profile must be one of/);
  });

  it("rejects creation when active goal exists", () => {
    const repo = freshRepo();
    repo.create({ session_id: "s1", objective: "first", token_budget: null, budget_profile: null });
    expect(() => repo.create({ session_id: "s1", objective: "second", token_budget: null, budget_profile: null })).toThrow(/already exists.*active/);
  });

  it("rejects creation when paused goal exists", () => {
    const repo = freshRepo();
    const first = repo.create({ session_id: "s1", objective: "first", token_budget: null, budget_profile: null });
    repo.pause("s1", first.goal_id, "user");
    expect(() => repo.create({ session_id: "s1", objective: "second", token_budget: null, budget_profile: null })).toThrow(/already exists.*paused/);
  });

  it("rejects creation when blocked goal exists", () => {
    const repo = freshRepo();
    const first = repo.create({ session_id: "s1", objective: "first", token_budget: null, budget_profile: null });
    repo.markBlocked("s1", first.goal_id, "waiting on user input");
    expect(() => repo.create({ session_id: "s1", objective: "second", token_budget: null, budget_profile: null })).toThrow(/already exists.*blocked/);
  });

  it("replaces a complete goal with goal_replaced event", () => {
    const repo = freshRepo();
    const first = repo.create({ session_id: "s1", objective: "first", token_budget: null, budget_profile: null });
    repo.markComplete("s1", first.goal_id);
    const second = repo.create({ session_id: "s1", objective: "second", token_budget: null, budget_profile: null });
    expect(second.goal_id).not.toBe(first.goal_id);
    expect(second.status).toBe("active");
    expect(second.subagent_tokens).toBe(0);

    const events = repo.listEvents("s1");
    expect(events.find(e => e.event_type === "goal_replaced")).toBeTruthy();
  });

  it("replacement resets continuation and wall-clock caps", () => {
    const repo = freshRepo();
    const first = repo.create({ session_id: "s1", objective: "first", token_budget: null, budget_profile: null });
    repo["db"]
      .prepare("UPDATE goals SET continuations_remaining = 3, max_wall_clock_seconds = 999999 WHERE session_id = 's1'")
      .run();
    repo.markComplete("s1", first.goal_id);

    const second = repo.create({ session_id: "s1", objective: "second", token_budget: null, budget_profile: null });

    expect(second.continuations_remaining).toBe(1000000);
    expect(second.max_wall_clock_seconds).toBe(315360000);
  });

  it("rejects empty objective", () => {
    const repo = freshRepo();
    expect(() => repo.create({ session_id: "s1", objective: "", token_budget: null, budget_profile: null })).toThrow();
  });

  it("rejects objective > 4000 chars", () => {
    const repo = freshRepo();
    expect(() => repo.create({ session_id: "s1", objective: "a".repeat(4001), token_budget: null, budget_profile: null })).toThrow();
  });
});

describe("GoalsRepo.markComplete", () => {
  it("transitions active → complete and flushes wall-clock", () => {
    const repo = freshRepo();
    const g = repo.create({ session_id: "s1", objective: "x", token_budget: null, budget_profile: null });
    // simulate 2s elapsed
    repo.testHelper_setResumeAt(g.session_id, Date.now() - 2000);
    repo.markComplete("s1", g.goal_id);
    const after = repo.getBySession("s1")!;
    expect(after.status).toBe("complete");
    expect(after.resume_at_ms).toBeNull();
    expect(after.time_used_seconds).toBeGreaterThanOrEqual(2);
  });

  it("allows evaluator completion from accounting_error pause", () => {
    const repo = freshRepo();
    const g = repo.create({ session_id: "s1", objective: "x", token_budget: null, budget_profile: null });
    repo.pause("s1", g.goal_id, "accounting_error");
    repo["db"].prepare("UPDATE goals SET accounting_uncertain = 1 WHERE session_id = 's1'").run();
    repo.recordVerdict("s1", g.goal_id, "complete", "verified", null);

    repo.markComplete("s1", g.goal_id, "evaluator");

    const after = repo.getBySession("s1")!;
    expect(after.status).toBe("complete");
    expect(after.paused_reason).toBeNull();
    expect(after.accounting_uncertain).toBe(0);

    const event = repo["db"]
      .prepare("SELECT event_type, status_before, status_after, payload_json FROM goal_events WHERE session_id='s1' ORDER BY id DESC LIMIT 1")
      .get() as { event_type: string; status_before: string; status_after: string; payload_json: string };
    expect(event.event_type).toBe("goal_completed_by_evaluator");
    expect(event.status_before).toBe("paused");
    expect(event.status_after).toBe("complete");
    expect(JSON.parse(event.payload_json)).toMatchObject({
      completed_by: "evaluator",
      from_status: "paused",
      paused_reason: "accounting_error",
    });
  });

  it("rejects self-update completion from accounting_error pause", () => {
    const repo = freshRepo();
    const g = repo.create({ session_id: "s1", objective: "x", token_budget: null, budget_profile: null });
    repo.pause("s1", g.goal_id, "accounting_error");

    expect(() => repo.markComplete("s1", g.goal_id, "self_update")).toThrow(/accounting_error.*evaluator/);
    expect(repo.getBySession("s1")!.status).toBe("paused");
  });

  it("allows evaluator completion from budget_limited", () => {
    const repo = freshRepo();
    const g = repo.create({ session_id: "s1", objective: "x", token_budget: 1000, budget_profile: null });
    repo.testHelper_setStatus("s1", "budget_limited");
    repo.recordVerdict("s1", g.goal_id, "complete", "verified", null);

    repo.markComplete("s1", g.goal_id, "evaluator");

    const after = repo.getBySession("s1")!;
    expect(after.status).toBe("complete");
    expect(after.paused_reason).toBeNull();
    expect(after.accounting_uncertain).toBe(0);

    const event = repo["db"]
      .prepare("SELECT event_type, status_before, status_after, payload_json FROM goal_events WHERE session_id='s1' ORDER BY id DESC LIMIT 1")
      .get() as { event_type: string; status_before: string; status_after: string; payload_json: string };
    expect(event.event_type).toBe("goal_completed_by_evaluator");
    expect(event.status_before).toBe("budget_limited");
    expect(event.status_after).toBe("complete");
    expect(JSON.parse(event.payload_json)).toMatchObject({
      completed_by: "evaluator",
      from_status: "budget_limited",
    });
  });

  it("rejects self-update completion from budget_limited", () => {
    const repo = freshRepo();
    const g = repo.create({ session_id: "s1", objective: "x", token_budget: 1000, budget_profile: null });
    repo.testHelper_setStatus("s1", "budget_limited");

    expect(() => repo.markComplete("s1", g.goal_id, "self_update")).toThrow(/budget_limited.*evaluator/);
    expect(repo.getBySession("s1")!.status).toBe("budget_limited");
  });

  it("rejects completing an abandoned goal", () => {
    const repo = freshRepo();
    const g = repo.create({ session_id: "s1", objective: "x", token_budget: null, budget_profile: null });
    repo.abandon("s1", g.goal_id);
    expect(() => repo.markComplete("s1", g.goal_id)).toThrow(/cannot.*complete.*status/);
  });
});

describe("GoalsRepo.markBlocked", () => {
  it("transitions active to blocked and records reason", () => {
    const repo = freshRepo();
    const g = repo.create({ session_id: "s1", objective: "x", token_budget: null, budget_profile: null });
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
    const g = repo.create({ session_id: "s1", objective: "x", token_budget: null, budget_profile: null });
    repo.markComplete("s1", g.goal_id);
    expect(() => repo.markBlocked("s1", g.goal_id, "late blocker")).toThrow(/cannot mark blocked from status 'complete'/);
  });
});

describe("GoalsRepo.pause/resume", () => {
  it("pause(user) flushes wall-clock and clears resume_at", () => {
    const repo = freshRepo();
    const g = repo.create({ session_id: "s1", objective: "x", token_budget: null, budget_profile: null });
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
    const g = repo.create({ session_id: "s1", objective: "x", token_budget: null, budget_profile: null });
    repo.pause("s1", g.goal_id, "user");
    repo.resume("s1", g.goal_id);
    const after = repo.getBySession("s1")!;
    expect(after.status).toBe("active");
    expect(after.paused_reason).toBeNull();
    expect(after.resume_at_ms).toBeGreaterThan(0);
  });

  it("resume rejects cap-paused goals", () => {
    const repo = freshRepo();
    const g = repo.create({ session_id: "s1", objective: "x", token_budget: null, budget_profile: null });
    repo.pause("s1", g.goal_id, "continuation_cap");
    expect(() => repo.resume("s1", g.goal_id)).toThrow(/use \/goal-extend/i);
  });

  it("resume restarts a blocked goal", () => {
    const repo = freshRepo();
    const g = repo.create({ session_id: "s1", objective: "x", token_budget: null, budget_profile: null });
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
