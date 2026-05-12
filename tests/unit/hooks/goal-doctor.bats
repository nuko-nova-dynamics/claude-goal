#!/usr/bin/env bats

setup() {
  TMPDIR_TEST=$(mktemp -d)
  mkdir -p "$TMPDIR_TEST/plugin-root"
  export CLAUDE_PLUGIN_DATA="$TMPDIR_TEST"
  export DB_PATH="$TMPDIR_TEST/goals.db"
  export CLAUDE_PLUGIN_ROOT="$TMPDIR_TEST/plugin-root"
  # doctor intentionally runs without CLAUDE_SESSION_ID
  unset CLAUDE_SESSION_ID
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  export REPO_ROOT
  CLI="$REPO_ROOT/scripts/goal-cli.sh"
  export CLI
  "$REPO_ROOT/tests/helpers/init-test-db.sh" "$DB_PATH"
}
teardown() { rm -rf "$TMPDIR_TEST"; }

@test "doctor runs without session_id" {
  run "$CLI" doctor
  [ "$status" -eq 0 ] || [ "$status" -eq 4 ]
  [[ "$output" == *"claude-goal doctor"* ]] || [[ "$output" == *"plugin_data_writable"* ]]
}

@test "doctor --format=json outputs valid JSON" {
  run "$CLI" doctor --format=json
  # exit 0 (pass) or 4 (fail) are both valid
  [ "$status" -eq 0 ] || [ "$status" -eq 4 ]
  echo "$output" | jq -e '.version' >/dev/null
  echo "$output" | jq -e '.checks' >/dev/null
  echo "$output" | jq -e '.overall' >/dev/null
}

@test "doctor JSON includes all required check ids" {
  run "$CLI" doctor --format=json
  [ "$status" -eq 0 ] || [ "$status" -eq 4 ]
  IDS=$(echo "$output" | jq -r '.checks | map(.id) | join(",")')
  [[ "$IDS" == *"plugin_data_writable"* ]]
  [[ "$IDS" == *"schema_version"* ]]
  [[ "$IDS" == *"node_present"* ]]
  [[ "$IDS" == *"hook_scripts_executable"* ]]
  [[ "$IDS" == *"stale_leases"* ]]
  [[ "$IDS" == *"active_goals"* ]]
}

@test "doctor exits 4 when overall=fail and overall=fail appears in JSON" {
  # Point DB_PATH at a non-existent db so schema_version check fails
  export DB_PATH="$TMPDIR_TEST/nonexistent.db"
  run "$CLI" doctor --format=json
  # Should exit 4 because schema_version will fail
  [ "$status" -eq 4 ]
  OVERALL=$(echo "$output" | jq -r '.overall')
  [ "$OVERALL" = "fail" ]
}

@test "doctor reports hooks_enabled pass when no settings disable hooks" {
  # No settings files exist in $HOME or $PWD pointing at our isolated tmp
  HOME="$TMPDIR_TEST/home" PWD="$TMPDIR_TEST/work" run "$CLI" doctor --format=json
  [ "$status" -eq 0 ] || [ "$status" -eq 4 ]
  HOOKS=$(echo "$output" | jq -r '.checks[] | select(.id=="hooks_enabled") | .status')
  [ "$HOOKS" = "pass" ]
}

@test "doctor reports hooks_enabled fail when disableAllHooks=true in user settings" {
  FAKE_HOME="$TMPDIR_TEST/home-disabled"
  mkdir -p "$FAKE_HOME/.claude"
  echo '{"disableAllHooks": true}' > "$FAKE_HOME/.claude/settings.json"
  HOME="$FAKE_HOME" run "$CLI" doctor --format=json
  [ "$status" -eq 4 ]
  HOOKS=$(echo "$output" | jq -r '.checks[] | select(.id=="hooks_enabled") | .status')
  [ "$HOOKS" = "fail" ]
  DETAIL=$(echo "$output" | jq -r '.checks[] | select(.id=="hooks_enabled") | .detail')
  [[ "$DETAIL" == *"disableAllHooks=true"* ]]
}
