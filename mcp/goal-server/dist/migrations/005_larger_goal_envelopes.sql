CREATE TABLE goals_v5_new (
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
    continuations_remaining INTEGER NOT NULL DEFAULT 1000000 CHECK(continuations_remaining >= 0),
    max_wall_clock_seconds INTEGER NOT NULL DEFAULT 315360000 CHECK(max_wall_clock_seconds > 0),
    budget_limit_reported INTEGER NOT NULL DEFAULT 0 CHECK(budget_limit_reported IN (0,1)),
    version INTEGER NOT NULL DEFAULT 0,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    subagent_tokens INTEGER NOT NULL DEFAULT 0 CHECK(subagent_tokens >= 0),
    budget_profile TEXT CHECK(budget_profile IN ('quick','standard','deep','overnight') OR budget_profile IS NULL),
    budget_source TEXT NOT NULL DEFAULT 'none' CHECK(budget_source IN ('none','tokens','profile','auto'))
);

INSERT INTO goals_v5_new (
    session_id, goal_id, objective, status, paused_reason, token_budget,
    tokens_used, time_used_seconds, resume_at_ms, last_accounted_byte_offset,
    last_accounted_uuid, accounting_uncertain, last_continuation_at_ms,
    continuations_remaining, max_wall_clock_seconds, budget_limit_reported,
    version, created_at_ms, updated_at_ms, subagent_tokens, budget_profile,
    budget_source
)
SELECT
    session_id,
    goal_id,
    objective,
    CASE
      WHEN status = 'budget_limited'
        AND (
          tokens_used + subagent_tokens
        ) < CASE
          WHEN budget_profile = 'quick' AND COALESCE(token_budget, 0) < 2000000 THEN 2000000
          WHEN budget_profile = 'standard' AND COALESCE(token_budget, 0) < 10000000 THEN 10000000
          WHEN budget_profile = 'deep' AND COALESCE(token_budget, 0) < 100000000 THEN 100000000
          WHEN budget_profile = 'overnight' AND COALESCE(token_budget, 0) < 1000000000 THEN 1000000000
          ELSE COALESCE(token_budget, 0)
        END
      THEN 'active'
      ELSE status
    END,
    paused_reason,
    CASE
      WHEN budget_profile = 'quick' AND COALESCE(token_budget, 0) < 2000000 THEN 2000000
      WHEN budget_profile = 'standard' AND COALESCE(token_budget, 0) < 10000000 THEN 10000000
      WHEN budget_profile = 'deep' AND COALESCE(token_budget, 0) < 100000000 THEN 100000000
      WHEN budget_profile = 'overnight' AND COALESCE(token_budget, 0) < 1000000000 THEN 1000000000
      ELSE token_budget
    END,
    tokens_used,
    time_used_seconds,
    CASE
      WHEN status = 'budget_limited'
        AND (
          tokens_used + subagent_tokens
        ) < CASE
          WHEN budget_profile = 'quick' AND COALESCE(token_budget, 0) < 2000000 THEN 2000000
          WHEN budget_profile = 'standard' AND COALESCE(token_budget, 0) < 10000000 THEN 10000000
          WHEN budget_profile = 'deep' AND COALESCE(token_budget, 0) < 100000000 THEN 100000000
          WHEN budget_profile = 'overnight' AND COALESCE(token_budget, 0) < 1000000000 THEN 1000000000
          ELSE COALESCE(token_budget, 0)
        END
        AND resume_at_ms IS NULL
      THEN updated_at_ms
      ELSE resume_at_ms
    END,
    last_accounted_byte_offset,
    last_accounted_uuid,
    accounting_uncertain,
    last_continuation_at_ms,
    CASE
      WHEN budget_profile = 'quick' AND continuations_remaining < 50 THEN 50
      WHEN budget_profile = 'standard' AND continuations_remaining < 200 THEN 200
      WHEN budget_profile = 'deep' AND continuations_remaining < 1000 THEN 1000
      WHEN budget_profile = 'overnight' AND continuations_remaining < 5000 THEN 5000
      WHEN budget_source IN ('none', 'tokens') AND continuations_remaining < 1000000 THEN 1000000
      ELSE continuations_remaining
    END,
    CASE
      WHEN budget_profile = 'quick' AND max_wall_clock_seconds < 7200 THEN 7200
      WHEN budget_profile = 'standard' AND max_wall_clock_seconds < 28800 THEN 28800
      WHEN budget_profile = 'deep' AND max_wall_clock_seconds < 86400 THEN 86400
      WHEN budget_profile = 'overnight' AND max_wall_clock_seconds < 259200 THEN 259200
      WHEN budget_source IN ('none', 'tokens') AND max_wall_clock_seconds < 315360000 THEN 315360000
      ELSE max_wall_clock_seconds
    END,
    CASE
      WHEN status = 'budget_limited'
        AND (
          tokens_used + subagent_tokens
        ) < CASE
          WHEN budget_profile = 'quick' AND COALESCE(token_budget, 0) < 2000000 THEN 2000000
          WHEN budget_profile = 'standard' AND COALESCE(token_budget, 0) < 10000000 THEN 10000000
          WHEN budget_profile = 'deep' AND COALESCE(token_budget, 0) < 100000000 THEN 100000000
          WHEN budget_profile = 'overnight' AND COALESCE(token_budget, 0) < 1000000000 THEN 1000000000
          ELSE COALESCE(token_budget, 0)
        END
      THEN 0
      ELSE budget_limit_reported
    END,
    version,
    created_at_ms,
    updated_at_ms,
    subagent_tokens,
    budget_profile,
    budget_source
FROM goals;

DROP TABLE goals;
ALTER TABLE goals_v5_new RENAME TO goals;

UPDATE schema_version SET version = 5;
