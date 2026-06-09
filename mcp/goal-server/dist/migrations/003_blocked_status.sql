CREATE TABLE goals_new (
    session_id TEXT PRIMARY KEY NOT NULL,
    goal_id TEXT NOT NULL,
    objective TEXT NOT NULL CHECK(length(objective) BETWEEN 1 AND 4000),
    status TEXT NOT NULL CHECK(status IN ('active','paused','blocked','budget_limited','complete','abandoned')),
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
    updated_at_ms INTEGER NOT NULL,
    subagent_tokens INTEGER NOT NULL DEFAULT 0 CHECK(subagent_tokens >= 0)
);

INSERT INTO goals_new (
    session_id, goal_id, objective, status, paused_reason, token_budget,
    tokens_used, time_used_seconds, resume_at_ms, last_accounted_byte_offset,
    last_accounted_uuid, accounting_uncertain, last_continuation_at_ms,
    continuations_remaining, max_wall_clock_seconds, budget_limit_reported,
    version, created_at_ms, updated_at_ms, subagent_tokens
)
SELECT
    session_id, goal_id, objective, status, paused_reason, token_budget,
    tokens_used, time_used_seconds, resume_at_ms, last_accounted_byte_offset,
    last_accounted_uuid, accounting_uncertain, last_continuation_at_ms,
    continuations_remaining, max_wall_clock_seconds, budget_limit_reported,
    version, created_at_ms, updated_at_ms, subagent_tokens
FROM goals;

DROP TABLE goals;
ALTER TABLE goals_new RENAME TO goals;

UPDATE schema_version SET version = 3;
