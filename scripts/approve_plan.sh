#!/bin/bash
# PostToolUse hook on ExitPlanMode — idempotent backup for approval creation.
# Primary approval happens in validate_plan_quality.sh (PreToolUse).
# This is a safety net for state consistency.
source "$(dirname "$0")/common.sh"
init_hook

# Ensure approval is set (idempotent — validate_plan_quality.sh already did this)
state_write approved "1"

# Re-extract plan sections if plan_file is known
PLAN_FILE=$(state_read plan_file)

if [[ -n "$PLAN_FILE" && -f "$PLAN_FILE" ]]; then
    PLAN_CONTENT=$(cat "$PLAN_FILE" 2>/dev/null)

    OBJ=$(echo "$PLAN_CONTENT" \
        | sed -n '/^##[[:space:]]*[Oo]bjective/,/^##/p' \
        | tail -n +2 | grep -v '^## ' \
        | sed '/^[[:space:]]*$/d' \
        | head -3)
    state_write objective "$OBJ"

    SCOPE=$(echo "$PLAN_CONTENT" \
        | sed -n '/^##[[:space:]]*[Ss]cope/,/^##/p' \
        | tail -n +2 | grep -v '^## ' \
        | grep -E '^\s*-\s+' \
        | grep '/' \
        | sed 's/^[[:space:]]*-[[:space:]]*//' \
        | sed 's/[[:space:]]*$//' \
        | sed 's/`//g' \
        | while IFS= read -r p; do
            if [[ "$p" == ./* ]]; then
                echo "$(pwd)/${p#./}"
            elif [[ "$p" != /* && "$p" != '~'* ]]; then
                echo "$(pwd)/$p"
            else
                echo "$p"
            fi
          done)
    state_write scope "$SCOPE"

    CRIT=$(echo "$PLAN_CONTENT" \
        | sed -n '/^##[[:space:]]*[Ss]uccess[[:space:]]*[Cc]riteria/,/^##/p' \
        | tail -n +2 | grep -v '^## ' \
        | sed '/^[[:space:]]*$/d' \
        | head -3)
    state_write criteria "$CRIT"
fi

# Clean up planning state
state_remove planning

allow_with_context "Plan approved. Editing unlocked. Implement ONLY the approved changes. When done, run ~/.claude/scripts/clear_approval.sh then tell the user to /accept or /reject." "PostToolUse"
