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
  [[ "$CTX" == *"claude-goal MCP tools"* ]]
  EVT=$(echo "$output" | jq -r '.hookSpecificOutput.hookEventName // ""')
  [ "$EVT" = "UserPromptExpansion" ]
}

@test "expansion hook on /goal-start emits additionalContext with session_id" {
  INPUT='{"command_name":"goal-start","session_id":"sess-start","expanded_prompt":"some body"}'
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/user-prompt-expansion.sh"
  [ "$status" -eq 0 ]
  CTX=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // ""')
  [[ "$CTX" == *"sess-start"* ]]
  [[ "$CTX" == *"claude-goal MCP tools"* ]]
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

@test "expansion hook on ordinary prose emits no additionalContext" {
  INPUT='{"session_id":"sess-prose","prompt":"fix this bug and run tests"}'
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/user-prompt-expansion.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || ! echo "$output" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
}

@test "expansion hook missing session_id exits 0 silently" {
  INPUT='{"command_name":"goal","expanded_prompt":"x"}'
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/user-prompt-expansion.sh"
  [ "$status" -eq 0 ]
}

@test "expansion hook on namespaced claude-goal:goal emits additionalContext" {
  INPUT='{"command_name":"claude-goal:goal","session_id":"sess-ns","expanded_prompt":"build something"}'
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/user-prompt-expansion.sh"
  [ "$status" -eq 0 ]
  CTX=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // ""')
  [[ "$CTX" == *"sess-ns"* ]]
  EVT=$(echo "$output" | jq -r '.hookSpecificOutput.hookEventName // ""')
  [ "$EVT" = "UserPromptExpansion" ]
}

@test "expansion hook on namespaced claude-goal:goal-start emits additionalContext" {
  INPUT='{"command_name":"claude-goal:goal-start","session_id":"sess-start-ns","expanded_prompt":"build something"}'
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/user-prompt-expansion.sh"
  [ "$status" -eq 0 ]
  CTX=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // ""')
  [[ "$CTX" == *"sess-start-ns"* ]]
  EVT=$(echo "$output" | jq -r '.hookSpecificOutput.hookEventName // ""')
  [ "$EVT" = "UserPromptExpansion" ]
}

@test "expansion hook on unrelated namespaced command emits no additionalContext" {
  INPUT='{"command_name":"something:else","session_id":"sess-abc","expanded_prompt":"x"}'
  run bash -c "echo '$INPUT' | $REPO_ROOT/scripts/user-prompt-expansion.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || ! echo "$output" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
}
