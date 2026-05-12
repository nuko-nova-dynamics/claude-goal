ALTER TABLE goals
  ADD COLUMN subagent_tokens INTEGER NOT NULL DEFAULT 0 CHECK(subagent_tokens >= 0);

CREATE TABLE IF NOT EXISTS subagent_token_cursors (
    session_id TEXT NOT NULL,
    goal_id TEXT NOT NULL,
    agent_id TEXT NOT NULL,
    transcript_path TEXT NOT NULL,
    tokens_used INTEGER NOT NULL DEFAULT 0 CHECK(tokens_used >= 0),
    last_accounted_byte_offset INTEGER NOT NULL DEFAULT 0,
    last_accounted_uuid TEXT,
    accounting_uncertain INTEGER NOT NULL DEFAULT 0 CHECK(accounting_uncertain IN (0,1)),
    updated_at_ms INTEGER NOT NULL,
    PRIMARY KEY (session_id, goal_id, agent_id)
);

UPDATE schema_version SET version = 2;
