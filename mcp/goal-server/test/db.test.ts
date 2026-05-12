import { describe, it, expect, beforeEach } from "vitest";
import { openDb, runMigrations, getSchemaVersion } from "../src/db.js";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

describe("db migrations", () => {
  let dbPath: string;
  const initialMigration = () => readFileSync(join(process.cwd(), "src/migrations/001_initial.sql"), "utf8");
  const subagentMigration = () => readFileSync(join(process.cwd(), "src/migrations/002_subagent_tokens.sql"), "utf8");

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
    db.exec(initialMigration());

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

    expect(() => runMigrations(db, migrationsDir)).toThrow();
    expect(getSchemaVersion(db)).toBe(1);
    expect(db.prepare("SELECT name FROM pragma_table_info('goals') WHERE name = 'subagent_tokens'").get()).toBeUndefined();
    expect(db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='subagent_token_cursors'").get()).toBeUndefined();

    writeFileSync(join(migrationsDir, "002_subagent_tokens.sql"), subagentMigration());

    runMigrations(db, migrationsDir);
    expect(getSchemaVersion(db)).toBe(2);
    expect(db.prepare("SELECT name FROM pragma_table_info('goals') WHERE name = 'subagent_tokens'").get()).toBeTruthy();
    expect(db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='subagent_token_cursors'").get()).toBeTruthy();
  });

  it("rejects a migration set with 001 and 003 but missing expected 002", () => {
    const db = openDb(dbPath);
    const migrationsDir = mkdtempSync(join(tmpdir(), "claude-goal-migrations-"));
    writeFileSync(join(migrationsDir, "001_initial.sql"), initialMigration());
    writeFileSync(join(migrationsDir, "003_future.sql"), "UPDATE schema_version SET version = 3;");

    expect(() => runMigrations(db, migrationsDir)).toThrow(/db schema version 1 after migrations; expected 2/);
    expect(getSchemaVersion(db)).toBe(1);
  });
});
