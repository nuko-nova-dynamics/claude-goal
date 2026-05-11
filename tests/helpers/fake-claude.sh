#!/usr/bin/env bash
# tests/helpers/fake-claude.sh
#
# Bash library sourced by .bats tests to simulate Claude Code's per-turn
# transcript writes and hook stdin payloads. Lets integration tests drive
# Stop, PostToolBatch, SessionStart, and UserPromptExpansion hooks
# deterministically without a real `claude` CLI.
#
# Usage in .bats:
#   load ../../helpers/fake-claude.sh
#   fake_claude_init
#   fake_claude_user_message "hello"
#   run fake_claude_stop_hook
#
# Globals set by fake_claude_init:
#   FAKE_SESSION_ID  – generated UUID
#   FAKE_TRANSCRIPT  – path to the JSONL transcript file
#   FAKE_DATA_DIR    – tmp dir used as CLAUDE_PLUGIN_DATA

# Repo root relative to this file: tests/helpers/ → tests/ → repo/
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ---------------------------------------------------------------------------
# fake_claude_init [session_id] [data_dir]
#   Initialize a fake-claude session. Idempotent — safe to call twice.
# ---------------------------------------------------------------------------
fake_claude_init() {
  local sid="${1:-}"
  local data_dir="${2:-}"

  if [[ -z "$sid" ]]; then
    sid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  fi
  if [[ -z "$data_dir" ]]; then
    data_dir="$(mktemp -d)"
  fi

  FAKE_SESSION_ID="$sid"
  FAKE_DATA_DIR="$data_dir"
  FAKE_TRANSCRIPT="$FAKE_DATA_DIR/transcript.jsonl"

  # Create empty transcript
  : > "$FAKE_TRANSCRIPT"

  export FAKE_SESSION_ID FAKE_DATA_DIR FAKE_TRANSCRIPT
  export CLAUDE_PLUGIN_DATA="$FAKE_DATA_DIR"
  export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
}

# ---------------------------------------------------------------------------
# fake_claude_cleanup
#   Remove temp data dir. Safe to call from bats teardown().
# ---------------------------------------------------------------------------
fake_claude_cleanup() {
  if [[ -n "${FAKE_DATA_DIR:-}" && -d "$FAKE_DATA_DIR" ]]; then
    rm -rf "$FAKE_DATA_DIR"
  fi
}

# ---------------------------------------------------------------------------
# fake_claude_user_message <text>
#   Append a user message JSONL line to the transcript.
# ---------------------------------------------------------------------------
fake_claude_user_message() {
  local text="${1:?fake_claude_user_message: text required}"
  local uuid
  uuid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  jq -nc \
    --arg uuid "$uuid" \
    --arg text "$text" \
    '{
      type: "user",
      uuid: $uuid,
      message: {
        role: "user",
        content: [{ type: "text", text: $text }]
      }
    }' >> "$FAKE_TRANSCRIPT"
}

# ---------------------------------------------------------------------------
# fake_claude_assistant_message <text> [input_tokens] [output_tokens]
#                               [cache_creation_tokens] [cache_read_tokens]
#   Append an assistant message JSONL line to the transcript.
# ---------------------------------------------------------------------------
fake_claude_assistant_message() {
  local text="${1:?fake_claude_assistant_message: text required}"
  local in_tok="${2:-0}"
  local out_tok="${3:-0}"
  local cache_create="${4:-0}"
  local cache_read="${5:-0}"
  local uuid
  uuid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  jq -nc \
    --arg uuid "$uuid" \
    --arg text "$text" \
    --argjson in_tok "$in_tok" \
    --argjson out_tok "$out_tok" \
    --argjson cache_create "$cache_create" \
    --argjson cache_read "$cache_read" \
    '{
      type: "assistant",
      uuid: $uuid,
      message: {
        role: "assistant",
        content: [{ type: "text", text: $text }],
        usage: {
          input_tokens: $in_tok,
          output_tokens: $out_tok,
          cache_creation_input_tokens: $cache_create,
          cache_read_input_tokens: $cache_read
        }
      }
    }' >> "$FAKE_TRANSCRIPT"
}

# ---------------------------------------------------------------------------
# fake_claude_tool_use <tool_name> <input_json> [input_tokens] [output_tokens]
#   Append an assistant JSONL line whose content includes a tool_use block.
# ---------------------------------------------------------------------------
fake_claude_tool_use() {
  local tool_name="${1:?fake_claude_tool_use: tool_name required}"
  local input_json="${2:?fake_claude_tool_use: input_json required}"
  local in_tok="${3:-0}"
  local out_tok="${4:-0}"
  local uuid tool_id
  uuid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  tool_id="toolu_$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-' | cut -c1-20)"
  jq -nc \
    --arg uuid "$uuid" \
    --arg tool_id "$tool_id" \
    --arg tool_name "$tool_name" \
    --argjson input_json "$input_json" \
    --argjson in_tok "$in_tok" \
    --argjson out_tok "$out_tok" \
    '{
      type: "assistant",
      uuid: $uuid,
      message: {
        role: "assistant",
        content: [{
          type: "tool_use",
          id: $tool_id,
          name: $tool_name,
          input: $input_json
        }],
        usage: {
          input_tokens: $in_tok,
          output_tokens: $out_tok,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 0
        }
      }
    }' >> "$FAKE_TRANSCRIPT"
}

# ---------------------------------------------------------------------------
# _fake_claude_fire_hook <script_path> <stdin_json>
#   Internal helper: pipes <stdin_json> into the hook script.
# ---------------------------------------------------------------------------
_fake_claude_fire_hook() {
  local script="$1"
  local payload="$2"
  CLAUDE_PLUGIN_DATA="$FAKE_DATA_DIR" \
  CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash -c "echo $(printf '%q' "$payload") | bash $(printf '%q' "$script")"
}

# ---------------------------------------------------------------------------
# fake_claude_stop_hook [extra_fields_json]
#   Fire the Stop hook with the current transcript.
#   extra_fields_json: optional additional JSON fields merged into the payload.
# ---------------------------------------------------------------------------
fake_claude_stop_hook() {
  local extra="${1:-{}}"
  local payload
  payload=$(jq -nc \
    --arg sid "$FAKE_SESSION_ID" \
    --arg transcript "$FAKE_TRANSCRIPT" \
    --argjson extra "$extra" \
    '{
      session_id: $sid,
      transcript_path: $transcript,
      stop_hook_active: false,
      cwd: env.PWD
    } + $extra')
  _fake_claude_fire_hook "$REPO_ROOT/scripts/stop.sh" "$payload"
}

# ---------------------------------------------------------------------------
# fake_claude_posttool_hook [extra_fields_json]
#   Fire the PostToolBatch hook with the current transcript.
# ---------------------------------------------------------------------------
fake_claude_posttool_hook() {
  local extra="${1:-{}}"
  local payload
  payload=$(jq -nc \
    --arg sid "$FAKE_SESSION_ID" \
    --arg transcript "$FAKE_TRANSCRIPT" \
    --argjson extra "$extra" \
    '{
      session_id: $sid,
      transcript_path: $transcript,
      cwd: env.PWD
    } + $extra')
  _fake_claude_fire_hook "$REPO_ROOT/scripts/post-tool-batch.sh" "$payload"
}

# ---------------------------------------------------------------------------
# fake_claude_session_start_hook <source> [extra_fields_json]
#   Fire the SessionStart hook.
#   source: startup|resume|clear|compact
# ---------------------------------------------------------------------------
fake_claude_session_start_hook() {
  local source="${1:?fake_claude_session_start_hook: source required}"
  local extra="${2:-{}}"
  local payload
  payload=$(jq -nc \
    --arg sid "$FAKE_SESSION_ID" \
    --arg transcript "$FAKE_TRANSCRIPT" \
    --arg source "$source" \
    --argjson extra "$extra" \
    '{
      session_id: $sid,
      transcript_path: $transcript,
      source: $source,
      cwd: env.PWD
    } + $extra')
  _fake_claude_fire_hook "$REPO_ROOT/scripts/session-start.sh" "$payload"
}

# ---------------------------------------------------------------------------
# fake_claude_user_prompt_expansion_hook <prompt_text> [command_name]
#   Fire the UserPromptExpansion hook.
# ---------------------------------------------------------------------------
fake_claude_user_prompt_expansion_hook() {
  local prompt="${1:?fake_claude_user_prompt_expansion_hook: prompt required}"
  local command_name="${2:-goal}"
  local payload
  payload=$(jq -nc \
    --arg sid "$FAKE_SESSION_ID" \
    --arg transcript "$FAKE_TRANSCRIPT" \
    --arg prompt "$prompt" \
    --arg command_name "$command_name" \
    '{
      session_id: $sid,
      transcript_path: $transcript,
      prompt: $prompt,
      command_name: $command_name
    }')
  _fake_claude_fire_hook "$REPO_ROOT/scripts/user-prompt-expansion.sh" "$payload"
}
