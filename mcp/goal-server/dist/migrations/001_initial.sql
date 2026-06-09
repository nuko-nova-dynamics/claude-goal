PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA busy_timeout = 5000;

CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY);
INSERT OR IGNORE INTO schema_version VALUES (1);

CREATE TABLE IF NOT EXISTS goals (
    session_id TEXT PRIMARY KEY NOT NULL,
    goal_id TEXT NOT NULL,
    objective TEXT NOT NULL CHECK(length(objective) BETWEEN 1 AND 4000),
    status TEXT NOT NULL CHECK(status IN ('active','paused','budget_limited','complete','abandoned')),
    paused_reason TEXT CHECK(paused_reason IN ('user','continuation_cap','wall_clock_cap','cleared','degraded','accounting_error') OR paused_reason IS NULL),
    token_budget INTEGER CHECK(token_budget IS NULL OR token_budget > 0),
    tokens_used INTEGER NOT NULL DEFAULT 0 CHECK(tokens_used >= 0),
    time_used_seconds INTEGER NOT NULL DEFAULT 0 CHECK(time_used_seconds >= 0),
    resume_at_ms INTEGER,
    last_accounted_byte_offset INTEGER NOT NULL DEFAULT 0,
    last_accounted_uuid TEXT,
    accounting_uncertain INTEGER NOT NULL DEFAULT 0 CHECK(accounting_uncertain IN (0,1)),
    last_continuation_at_ms INTEGER,
    continuations_remaining INTEGER NOT NULL DEFAULT 50 CHECK(continuations_remaining >= 0),
    max_wall_clock_seconds INTEGER NOT NULL DEFAULT 14400 CHECK(max_wall_clock_seconds > 0),
    budget_limit_reported INTEGER NOT NULL DEFAULT 0 CHECK(budget_limit_reported IN (0,1)),
    version INTEGER NOT NULL DEFAULT 0,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS continuation_leases (
    session_id TEXT PRIMARY KEY NOT NULL,
    goal_id TEXT NOT NULL,
    owner_pid INTEGER NOT NULL,
    owner_host TEXT NOT NULL,
    acquired_at_ms INTEGER NOT NULL,
    expires_at_ms INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS goal_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    goal_id TEXT NOT NULL,
    hook_name TEXT,
    event_type TEXT NOT NULL,
    status_before TEXT,
    status_after TEXT,
    tokens_delta INTEGER,
    version_before INTEGER,
    version_after INTEGER,
    decision TEXT,
    stop_hook_active INTEGER,
    pid INTEGER,
    payload_json TEXT,
    created_at_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_goal_events_session ON goal_events(session_id, created_at_ms);
