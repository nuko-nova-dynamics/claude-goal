#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "plugin ships goal-evaluator custom subagent" {
  [ -f "$REPO_ROOT/agents/goal-evaluator.md" ]
  grep -q '^name: goal-evaluator$' "$REPO_ROOT/agents/goal-evaluator.md"
  grep -q '^description: .*claude-goal' "$REPO_ROOT/agents/goal-evaluator.md"
  grep -q 'Return JSON only' "$REPO_ROOT/agents/goal-evaluator.md"
  grep -q 'Do not call `update_goal`' "$REPO_ROOT/agents/goal-evaluator.md"
}

@test "Stop hooks do not include experimental agent hook" {
  jq -e '
    [
      .hooks.Stop[]?.hooks[]? | select(.type == "agent")
    ] | length == 0
  ' "$REPO_ROOT/hooks/hooks.json" >/dev/null
}

@test "continuation prompt dispatches plugin-scoped evaluator before evaluator completion" {
  grep -q 'claude-goal:goal-evaluator' "$REPO_ROOT/prompts/continuation.md"
  grep -q 'completed_by.*evaluator' "$REPO_ROOT/prompts/continuation.md"
  grep -q 'self_update' "$REPO_ROOT/prompts/continuation.md"
}
