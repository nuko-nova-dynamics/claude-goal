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

@test "goal-start skill supports explicit natural-language goal requests" {
  grep -q 'explicitly asks in natural language' "$REPO_ROOT/skills/goal-start/SKILL.md"
  grep -q 'set up a goal and continue' "$REPO_ROOT/skills/goal-start/SKILL.md"
  grep -q 'Do not use this skill for ordinary tasks' "$REPO_ROOT/skills/goal-start/SKILL.md"
  grep -q 'Natural-language form without an explicit budget: set `budget_profile` to `auto`' "$REPO_ROOT/skills/goal-start/SKILL.md"
  grep -q 'Never send both' "$REPO_ROOT/skills/goal-start/SKILL.md"
}

@test "create_goal MCP metadata allows explicit prose starts but forbids silent inference" {
  grep -q 'explicitly asks in natural language' "$REPO_ROOT/mcp/goal-server/src/tool-definitions.ts"
  grep -q 'do not infer goals from ordinary tasks' "$REPO_ROOT/mcp/goal-server/src/tool-definitions.ts"
  grep -q "budget_profile='auto' is the smart default" "$REPO_ROOT/mcp/goal-server/src/tool-definitions.ts"
}
