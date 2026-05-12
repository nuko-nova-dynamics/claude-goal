import { describe, it, expect, beforeEach } from "vitest";
import { openDb, runMigrations, getSchemaVersion } from "../src/db.js";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

describe("db migrations", () => {
  let dbPath: string;

  beforeEach(() => {
    const dir = mkdtempSync(join(tmpdir(), "claude-goal-test-"));
    dbPath = join(dir, "goals.db");
  });

  it("creates schema_version=2 on fresh DB", () => {
    const db = openDb(dbPath);
    runMigrations(db);
    expect(getSchemaVersion(db)).toBe(2);
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

  it("is idempotent (running twice does not fail)", () => {
    const db = openDb(dbPath);
    runMigrations(db);
    runMigrations(db);
    expect(getSchemaVersion(db)).toBe(2);
  });

  it("migrates an existing v1 database to v2", () => {
    const db = openDb(dbPath);
    db.exec(readFileSync(join(process.cwd(), "src/migrations/001_initial.sql"), "utf8"));

    runMigrations(db);

    expect(getSchemaVersion(db)).toBe(2);
    const subagentColumn = db.prepare("SELECT name FROM pragma_table_info('goals') WHERE name = 'subagent_tokens'").get();
    expect(subagentColumn).toBeTruthy();
    const cursorTable = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='subagent_token_cursors'").get();
    expect(cursorTable).toBeTruthy();
  });

  it("is idempotent for an existing v2 database", () => {
    const db = openDb(dbPath);
    runMigrations(db);
    expect(getSchemaVersion(db)).toBe(2);

    runMigrations(db);

    expect(getSchemaVersion(db)).toBe(2);
  });

  it("rejects DB ahead of plugin version", () => {
    const db = openDb(dbPath);
    runMigrations(db);
    db.prepare("UPDATE schema_version SET version = 999").run();
    expect(() => runMigrations(db)).toThrow(/db schema version 999 ahead/);
  });
});
