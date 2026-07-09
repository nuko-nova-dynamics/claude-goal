#!/usr/bin/env bash
# Usage: render_template TEMPLATE_PATH > stdout
# Required env: OBJECTIVE_RAW (will be XML-escaped to OBJECTIVE),
#               TOKENS_USED, WORKER_TOKENS_USED, SUBAGENT_TOKENS,
#               TOKEN_BUDGET, REMAINING_TOKENS,
#               TIME_USED_SECONDS, BUDGET_WARNING (may be empty),
#               SESSION_ID (when rendering continuation prompts)

render_template() {
  local tmpl="$1"
  local OBJECTIVE
  OBJECTIVE=$(printf '%s' "$OBJECTIVE_RAW" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
  export OBJECTIVE
  envsubst '${OBJECTIVE} ${TOKENS_USED} ${WORKER_TOKENS_USED} ${SUBAGENT_TOKENS} ${TOKEN_BUDGET} ${REMAINING_TOKENS} ${TIME_USED_SECONDS} ${BUDGET_WARNING} ${SESSION_ID}' < "$tmpl"
}
