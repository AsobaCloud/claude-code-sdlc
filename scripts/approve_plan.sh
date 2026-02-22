#!/bin/bash
# PostToolUse hook on ExitPlanMode — idempotent backup for approval creation.
# NOTE: Primary approval creation now happens in validate_plan_quality.sh (PreToolUse).
# This PostToolUse hook is retained as an idempotent backup in case PreToolUse
# creates approval but PostToolUse context is needed for state consistency.
source "$(dirname "$0")/common.sh"
init_hook

# ── Create approval markers (session + persistent) ──
state_write approved "1"
persist_write approved "1"

# ── Extract objective, scope, criteria from validated plan ──
PLAN_FILE=$(state_read plan_file)

if [[ -n "$PLAN_FILE" && -f "$PLAN_FILE" ]]; then
    PLAN_CONTENT=$(cat "$PLAN_FILE" 2>/dev/null)

    # Extract Objective
    OBJ=$(echo "$PLAN_CONTENT" \
        | sed -n '/^##[[:space:]]*[Oo]bjective/,/^##/p' \
        | tail -n +2 | grep -v '^## ' \
        | sed '/^[[:space:]]*$/d' \
        | head -3)
    echo "$OBJ" > "$(state_file objective)"
    echo "$OBJ" > "$(persist_file objective)"

    # Extract Scope
    SCOPE=$(echo "$PLAN_CONTENT" \
        | sed -n '/^##[[:space:]]*[Ss]cope/,/^##/p' \
        | tail -n +2 | grep -v '^## ' \
        | grep -E '^\s*-\s+' \
        | grep '/' \
        | sed 's/^[[:space:]]*-[[:space:]]*//' \
        | sed 's/[[:space:]]*$//' \
        | sed 's/`//g')
    echo "$SCOPE" > "$(state_file scope)"
    echo "$SCOPE" > "$(persist_file scope)"

    # Extract Success Criteria
    CRIT=$(echo "$PLAN_CONTENT" \
        | sed -n '/^##[[:space:]]*[Ss]uccess[[:space:]]*[Cc]riteria/,/^##/p' \
        | tail -n +2 | grep -v '^## ' \
        | sed '/^[[:space:]]*$/d' \
        | head -3)
    echo "$CRIT" > "$(state_file criteria)"
    echo "$CRIT" > "$(persist_file criteria)"
fi

# Clean up planning state (session + persistent)
state_remove planning
state_remove explore_count
state_remove exploration_log
persist_remove planning
persist_remove explore_count
persist_remove exploration_log

allow_with_context "Plan approved. Editing unlocked. Implement ONLY the approved changes. When done, run ~/.claude/scripts/clear_approval.sh then tell the user to /accept or /reject." "PostToolUse"
