#!/usr/bin/env bash
set -uo pipefail
INPUT=$(cat 2>/dev/null || echo "")
[[ -z "$INPUT" ]] && exit 0

COMMAND_NAME=$(echo "$INPUT" | jq -r '.command_name // ""' 2>/dev/null || echo "")
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || echo "")

# Only act on /goal
if [[ "$COMMAND_NAME" != "goal" ]]; then
  exit 0
fi

# Need session_id to inject; if absent, fail open
[[ -z "$SESSION_ID" ]] && exit 0

# Emit hookSpecificOutput.additionalContext per P19-confirmed mechanism
jq -n --arg sid "$SESSION_ID" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptExpansion",
    additionalContext: ("When calling create_goal, use session_id=\"" + $sid + "\".")
  }
}'
