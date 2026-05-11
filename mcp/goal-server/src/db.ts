import Database from "better-sqlite3";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const EXPECTED_VERSION = 1;

export function openDb(path: string): Database.Database {
  const db = new Database(path);
  db.pragma("journal_mode = WAL");
  db.pragma("synchronous = NORMAL");
  db.pragma("busy_timeout = 5000");
  return db;
}

export function getSchemaVersion(db: Database.Database): number {
  const row = db.prepare("SELECT version FROM schema_version LIMIT 1").get() as { version: number } | undefined;
  return row?.version ?? 0;
}

export function runMigrations(db: Database.Database): void {
  const versionTableExists = db.prepare(
    "SELECT name FROM sqlite_master WHERE type='table' AND name='schema_version'"
  ).get();

  if (versionTableExists) {
    const v = getSchemaVersion(db);
    if (v > EXPECTED_VERSION) {
      throw new Error(`db schema version ${v} ahead of plugin (expected ${EXPECTED_VERSION}); please upgrade the plugin`);
    }
    if (v === EXPECTED_VERSION) return;
  }

  const sqlPath = join(__dirname, "migrations", "001_initial.sql");
  const sql = readFileSync(sqlPath, "utf8");
  db.exec(sql);
}
