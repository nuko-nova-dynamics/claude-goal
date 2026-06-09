import { describe, it, expect, beforeEach } from "vitest";
import { openDb, runMigrations, getSchemaVersion } from "../src/db.js";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

describe("db migrations", () => {
  let dbPath: string;
  const initialMigration = () => readFileSync(join(process.cwd(), "src/migrations/001_initial.sql"), "utf8");
  const subagentMigration = () => readFileSync(join(process.cwd(), "src/migrations/002_subagent_tokens.sql"), "utf8");
  const blockedMigration = () => readFileSync(join(process.cwd(), "src/migrations/003_blocked_status.sql"), "utf8");
  const budgetProfilesMigration = () => readFileSync(join(process.cwd(), "src/migrations/004_budget_profiles.sql"), "utf8");
  const largerGoalEnvelopesMigration = () => readFileSync(join(process.cwd(), "src/migrations/005_larger_goal_envelopes.sql"), "utf8");

  beforeEach(() => {
    const dir = mkdtempSync(join(tmpdir(), "claude-goal-test-"));
    dbPath = join(dir, "goals.db");
  });

  it("creates schema_version=5 on fresh DB", () => {
    const db = openDb(dbPath);
    runMigrations(db);
    expect(getSchemaVersion(db)).toBe(5);
  });

  it("creates goals, continuation_leases, goal_events, subagent_token_cursors tables", () => {
    const db = openDb(dbPath);
    runMigrations(db);
    const tables = db.prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").all() as { name: string }[];
    const names = tables.map(t => t.name);
    expect(names).toContain("goals");
    expect(names).toContain("continuation_leases");
    expect(names).toContain("goal_events");
    expect(names).toContain("subagent_token_cursors");
    expect(names).toContain("schema_version");
  });

  it("fresh v5 schema defaults omitted continuation and wall-clock caps to practical-unlimited", () => {
    const db = openDb(dbPath);
    runMigrations(db);
    db.prepare(`
      INSERT INTO goals (session_id, goal_id, objective, status, created_at_ms, updated_at_ms)
      VALUES ('s-defaults', 'g-defaults', 'x', 'active', 1, 1)
    `).run();

    const row = db.prepare(`
      SELECT continuations_remaining, max_wall_clock_seconds
      FROM goals WHERE session_id = 's-defaults'
    `).get() as { continuations_remaining: number; max_wall_clock_seconds: number };

    expect(row.continuations_remaining).toBe(1000000);
    expect(row.max_wall_clock_seconds).toBe(315360000);
  });

  it("is idempotent (running twice does not fail)", () => {
    const db = openDb(dbPath);
    runMigrations(db);
    runMigrations(db);
    expect(getSchemaVersion(db)).toBe(5);
  });

  it("migrates an existing v1 database to v5", () => {
    const db = openDb(dbPath);
    db.exec(initialMigration());

    runMigrations(db);

    expect(getSchemaVersion(db)).toBe(5);
    const subagentColumn = db.prepare("SELECT name FROM pragma_table_info('goals') WHERE name = 'subagent_tokens'").get();
    expect(subagentColumn).toBeTruthy();
    const cursorTable = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='subagent_token_cursors'").get();
    expect(cursorTable).toBeTruthy();
    const budgetProfileColumn = db.prepare("SELECT name FROM pragma_table_info('goals') WHERE name = 'budget_profile'").get();
    expect(budgetProfileColumn).toBeTruthy();
    const budgetSourceColumn = db.prepare("SELECT name FROM pragma_table_info('goals') WHERE name = 'budget_source'").get();
    expect(budgetSourceColumn).toBeTruthy();
    expect(() => db.prepare(`
      INSERT INTO goals (session_id, goal_id, objective, status, created_at_ms, updated_at_ms)
      VALUES ('s-blocked', 'g-blocked', 'x', 'blocked', 1, 1)
    `).run()).not.toThrow();
  });

  it("is idempotent for an existing v4 database", () => {
    const db = openDb(dbPath);
    db.exec(initialMigration());
    db.exec(subagentMigration());
    db.exec(blockedMigration());
    db.exec(budgetProfilesMigration());
    expect(getSchemaVersion(db)).toBe(4);

    runMigrations(db);

    expect(getSchemaVersion(db)).toBe(5);
  });

  it("rejects DB ahead of plugin version", () => {
    const db = openDb(dbPath);
    runMigrations(db);
    db.prepare("UPDATE schema_version SET version = 999").run();
    expect(() => runMigrations(db)).toThrow(/db schema version 999 ahead/);
  });

  it("rolls back a partially failing migration so rerun can recover", () => {
    const db = openDb(dbPath);
    const migrationsDir = mkdtempSync(join(tmpdir(), "claude-goal-migrations-"));
    writeFileSync(join(migrationsDir, "001_initial.sql"), initialMigration());
    writeFileSync(join(migrationsDir, "002_subagent_tokens.sql"), `
ALTER TABLE goals ADD COLUMN subagent_tokens INTEGER NOT NULL DEFAULT 0;
CREATE TABLE subagent_token_cursors (
  session_id TEXT NOT NULL
);
INSERT INTO missing_table VALUES (1);
UPDATE schema_version SET version = 2;
`);
    writeFileSync(join(migrationsDir, "003_blocked_status.sql"), blockedMigration());
    writeFileSync(join(migrationsDir, "004_budget_profiles.sql"), budgetProfilesMigration());

    expect(() => runMigrations(db, migrationsDir)).toThrow();
    expect(getSchemaVersion(db)).toBe(1);
    expect(db.prepare("SELECT name FROM pragma_table_info('goals') WHERE name = 'subagent_tokens'").get()).toBeUndefined();
    expect(db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='subagent_token_cursors'").get()).toBeUndefined();

    writeFileSync(join(migrationsDir, "002_subagent_tokens.sql"), subagentMigration());
    writeFileSync(join(migrationsDir, "005_larger_goal_envelopes.sql"), largerGoalEnvelopesMigration());

    runMigrations(db, migrationsDir);
    expect(getSchemaVersion(db)).toBe(5);
    expect(db.prepare("SELECT name FROM pragma_table_info('goals') WHERE name = 'subagent_tokens'").get()).toBeTruthy();
    expect(db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='subagent_token_cursors'").get()).toBeTruthy();
  });

  it("rejects a migration set missing expected 005", () => {
    const db = openDb(dbPath);
    const migrationsDir = mkdtempSync(join(tmpdir(), "claude-goal-migrations-"));
    writeFileSync(join(migrationsDir, "001_initial.sql"), initialMigration());
    writeFileSync(join(migrationsDir, "002_subagent_tokens.sql"), subagentMigration());
    writeFileSync(join(migrationsDir, "003_blocked_status.sql"), blockedMigration());

    expect(() => runMigrations(db, migrationsDir)).toThrow(/db schema version 3 after migrations; expected 5/);
    expect(getSchemaVersion(db)).toBe(3);
  });

  it("marks existing budgeted goals as token-sourced during v4 migration", () => {
    const db = openDb(dbPath);
    db.exec(initialMigration());
    db.exec(subagentMigration());
    db.exec(blockedMigration());
    db.prepare(`
      INSERT INTO goals (session_id, goal_id, objective, status, token_budget, created_at_ms, updated_at_ms)
      VALUES ('s-budgeted', 'g-budgeted', 'x', 'active', 1000, 1, 1)
    `).run();

    runMigrations(db);

    const row = db.prepare("SELECT budget_profile, budget_source FROM goals WHERE session_id = 's-budgeted'").get() as { budget_profile: string | null; budget_source: string };
    expect(row.budget_profile).toBeNull();
    expect(row.budget_source).toBe("tokens");
  });

  it("upgrades old profile envelopes to modern large minimums even after progress or modest extension", () => {
    const db = openDb(dbPath);
    db.exec(initialMigration());
    db.exec(subagentMigration());
    db.exec(blockedMigration());
    db.exec(budgetProfilesMigration());
    db.prepare(`
      INSERT INTO goals (
        session_id, goal_id, objective, status, token_budget, budget_profile,
        budget_source, continuations_remaining, max_wall_clock_seconds,
        created_at_ms, updated_at_ms
      ) VALUES
        ('s-deep', 'g-deep', 'x', 'active', 5000000, 'deep', 'profile', 140, 28800, 1, 1),
        ('s-standard', 'g-standard', 'x', 'active', 2000000, 'standard', 'profile', 80, 14400, 1, 1)
    `).run();

    runMigrations(db);

    const rows = db.prepare(`
      SELECT session_id, token_budget, continuations_remaining, max_wall_clock_seconds
      FROM goals ORDER BY session_id
    `).all() as {
      session_id: string;
      token_budget: number;
      continuations_remaining: number;
      max_wall_clock_seconds: number;
    }[];

    expect(getSchemaVersion(db)).toBe(5);
    expect(rows).toEqual([
      { session_id: "s-deep", token_budget: 100000000, continuations_remaining: 1000, max_wall_clock_seconds: 86400 },
      { session_id: "s-standard", token_budget: 10000000, continuations_remaining: 200, max_wall_clock_seconds: 28800 },
    ]);
  });

  it("upgrades old raw-token and unbounded turn/time caps to practical-unlimited", () => {
    const db = openDb(dbPath);
    db.exec(initialMigration());
    db.exec(subagentMigration());
    db.exec(blockedMigration());
    db.exec(budgetProfilesMigration());
    db.prepare(`
      INSERT INTO goals (
        session_id, goal_id, objective, status, token_budget, budget_source,
        continuations_remaining, max_wall_clock_seconds, created_at_ms, updated_at_ms
      ) VALUES
        ('s-none', 'g-none', 'x', 'active', NULL, 'none', 47, 14400, 1, 1),
        ('s-tokens', 'g-tokens', 'x', 'active', 75000000, 'tokens', 50, 28800, 1, 1)
    `).run();

    runMigrations(db);

    const rows = db.prepare(`
      SELECT session_id, token_budget, continuations_remaining, max_wall_clock_seconds
      FROM goals ORDER BY session_id
    `).all() as {
      session_id: string;
      token_budget: number | null;
      continuations_remaining: number;
      max_wall_clock_seconds: number;
    }[];

    expect(rows).toEqual([
      { session_id: "s-none", token_budget: null, continuations_remaining: 1000000, max_wall_clock_seconds: 315360000 },
      { session_id: "s-tokens", token_budget: 75000000, continuations_remaining: 1000000, max_wall_clock_seconds: 315360000 },
    ]);
  });

  it("resumes budget-limited profile rows when the new budget exceeds current usage", () => {
    const db = openDb(dbPath);
    db.exec(initialMigration());
    db.exec(subagentMigration());
    db.exec(blockedMigration());
    db.exec(budgetProfilesMigration());
    db.prepare(`
      INSERT INTO goals (
        session_id, goal_id, objective, status, token_budget, budget_profile,
        budget_source, tokens_used, subagent_tokens, budget_limit_reported,
        continuations_remaining, max_wall_clock_seconds, resume_at_ms,
        created_at_ms, updated_at_ms
      ) VALUES (
        's-deep', 'g-deep', 'x', 'budget_limited', 5000000, 'deep',
        'profile', 6000000, 1000, 1, 0, 28800, NULL, 1, 123456
      )
    `).run();

    runMigrations(db);

    const row = db.prepare(`
      SELECT status, token_budget, budget_limit_reported, continuations_remaining,
             max_wall_clock_seconds, resume_at_ms
      FROM goals WHERE session_id = 's-deep'
    `).get() as {
      status: string;
      token_budget: number;
      budget_limit_reported: number;
      continuations_remaining: number;
      max_wall_clock_seconds: number;
      resume_at_ms: number;
    };

    expect(row).toEqual({
      status: "active",
      token_budget: 100000000,
      budget_limit_reported: 0,
      continuations_remaining: 1000,
      max_wall_clock_seconds: 86400,
      resume_at_ms: 123456,
    });
  });
});
