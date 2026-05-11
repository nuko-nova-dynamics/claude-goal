import { describe, it, expect, beforeEach } from "vitest";
import { openDb, runMigrations, getSchemaVersion } from "../src/db.js";
import { unlinkSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

describe("db migrations", () => {
  let dbPath: string;

  beforeEach(() => {
    const dir = mkdtempSync(join(tmpdir(), "claude-goal-test-"));
    dbPath = join(dir, "goals.db");
  });

  it("creates schema_version=1 on fresh DB", () => {
    const db = openDb(dbPath);
    runMigrations(db);
    expect(getSchemaVersion(db)).toBe(1);
  });

  it("creates goals, continuation_leases, goal_events tables", () => {
    const db = openDb(dbPath);
    runMigrations(db);
    const tables = db.prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").all() as { name: string }[];
    const names = tables.map(t => t.name);
    expect(names).toContain("goals");
    expect(names).toContain("continuation_leases");
    expect(names).toContain("goal_events");
    expect(names).toContain("schema_version");
  });

  it("is idempotent (running twice does not fail)", () => {
    const db = openDb(dbPath);
    runMigrations(db);
    runMigrations(db);
    expect(getSchemaVersion(db)).toBe(1);
  });

  it("rejects DB ahead of plugin version", () => {
    const db = openDb(dbPath);
    runMigrations(db);
    db.prepare("UPDATE schema_version SET version = 999").run();
    expect(() => runMigrations(db)).toThrow(/db schema version 999 ahead/);
  });
});
