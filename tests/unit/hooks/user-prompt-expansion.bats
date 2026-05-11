#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export REPO_ROOT
  export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
}

@test "expansion hook on /goal emits additionalContext with session_id" {
  INPUT='{"command_name":"goal","session_id":"sess-abc","expanded_prompt":"some body"}'
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/user-prompt-expansion.sh"
  [ "$status" -eq 0 ]
  # Output must be JSON with hookSpecificOutput.additionalContext mentioning session_id
  CTX=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // ""')
  [[ "$CTX" == *"sess-abc"* ]]
  EVT=$(echo "$output" | jq -r '.hookSpecificOutput.hookEventName // ""')
  [ "$EVT" = "UserPromptExpansion" ]
}

@test "expansion hook on non-goal command emits no additionalContext" {
  INPUT='{"command_name":"help","session_id":"sess-abc","expanded_prompt":"x"}'
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/user-prompt-expansion.sh"
  [ "$status" -eq 0 ]
  # Output should be empty or have no additionalContext
  [ -z "$output" ] || ! echo "$output" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
}

@test "expansion hook missing session_id exits 0 silently" {
  INPUT='{"command_name":"goal","expanded_prompt":"x"}'
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/user-prompt-expansion.sh"
  [ "$status" -eq 0 ]
}
