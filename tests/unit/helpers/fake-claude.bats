#!/usr/bin/env bats

setup() {
  load ../../helpers/fake-claude.sh
  fake_claude_init
}

teardown() {
  fake_claude_cleanup
}

@test "init creates transcript and data dir" {
  [[ -f "$FAKE_TRANSCRIPT" ]]
  [[ -d "$FAKE_DATA_DIR" ]]
  [[ -n "$FAKE_SESSION_ID" ]]
}

@test "user_message appends one valid JSONL line" {
  fake_claude_user_message "hello"
  run bash -c "wc -l < '$FAKE_TRANSCRIPT' | tr -d ' '"
  [ "$output" = "1" ]
  run bash -c "jq -r '.type' '$FAKE_TRANSCRIPT'"
  [ "$output" = "user" ]
}

@test "assistant_message with usage fields appends correctly" {
  fake_claude_assistant_message "hi" 100 50 0 0
  run bash -c "jq -r '.message.usage.input_tokens' '$FAKE_TRANSCRIPT'"
  [ "$output" = "100" ]
}

@test "session_start_hook fires with source=startup and exits 0" {
  run fake_claude_session_start_hook startup
  [ "$status" = "0" ]
}

@test "stop_hook fires on transcript with no goal and exits cleanly" {
  fake_claude_user_message "hi"
  fake_claude_assistant_message "hello back" 10 5 0 0
  run fake_claude_stop_hook
  [ "$status" = "0" ]
  # No goal active → no decision block expected
}
