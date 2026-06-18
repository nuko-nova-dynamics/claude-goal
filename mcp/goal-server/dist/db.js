import Database from "better-sqlite3";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
const __dirname = dirname(fileURLToPath(import.meta.url));
const EXPECTED_VERSION = 5;
export function openDb(path) {
    const db = new Database(path);
    db.pragma("journal_mode = WAL");
    db.pragma("synchronous = NORMAL");
    db.pragma("busy_timeout = 5000");
    return db;
}
export function getSchemaVersion(db) {
    const row = db.prepare("SELECT version FROM schema_version LIMIT 1").get();
    return row?.version ?? 0;
}
function applyMigration(db, sql) {
    const lines = sql.split(/\r?\n/);
    const pragmaLines = lines.filter((line) => /^\s*PRAGMA\b/i.test(line));
    const transactionalSql = lines.filter((line) => !/^\s*PRAGMA\b/i.test(line)).join("\n");
    if (pragmaLines.length > 0) {
        db.exec(pragmaLines.join("\n"));
    }
    if (transactionalSql.trim().length > 0) {
        db.transaction(() => {
            db.exec(transactionalSql);
        })();
    }
}
export function runMigrations(db, migrationsDir = join(__dirname, "migrations")) {
    const migrations = readdirSync(migrationsDir)
        .map((name) => {
        const match = name.match(/^(\d{3})_.*\.sql$/);
        return match ? { version: Number(match[1]), name } : null;
    })
        .filter((entry) => entry !== null)
        .sort((a, b) => a.version - b.version);
    const versionTableExists = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='schema_version'").get();
    let currentVersion = 0;
    if (versionTableExists) {
        currentVersion = getSchemaVersion(db);
        if (currentVersion > EXPECTED_VERSION) {
            throw new Error(`db schema version ${currentVersion} ahead of plugin (expected ${EXPECTED_VERSION}); please upgrade the plugin`);
        }
        if (currentVersion === EXPECTED_VERSION)
            return;
    }
    for (const migration of migrations) {
        if (migration.version <= currentVersion)
            continue;
        if (migration.version > EXPECTED_VERSION)
            continue;
        const sql = readFileSync(join(migrationsDir, migration.name), "utf8");
        applyMigration(db, sql);
        currentVersion = getSchemaVersion(db);
    }
    const finalVersion = getSchemaVersion(db);
    if (finalVersion !== EXPECTED_VERSION) {
        throw new Error(`db schema version ${finalVersion} after migrations; expected ${EXPECTED_VERSION}`);
    }
}
