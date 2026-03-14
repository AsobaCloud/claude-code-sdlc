#!/bin/bash
# PostToolUse hook on ExitPlanMode — idempotent backup for approval creation.
# Primary approval happens in validate_plan_quality.sh (PreToolUse).
# This is a safety net for state consistency.
source "$(dirname "$0")/common.sh"
init_hook

# Ensure approval bundle is coherent (idempotent fallback for ExitPlanMode).
if ! approval_bundle_is_complete; then
    PLAN_FILE=$(resolve_plan_file)
    if [[ -n "$PLAN_FILE" && -f "$PLAN_FILE" ]]; then
        write_approval_bundle "$PLAN_FILE" || true
    fi
fi

# Clean up planning state
state_remove planning
state_remove planning_started_at

if approval_bundle_is_complete; then
    allow_with_context "Plan approved. Editing unlocked. Implement ONLY the approved changes. When done, run ~/.claude/scripts/clear_approval.sh then tell the user to /accept or /reject." "PostToolUse"
fi

# DO NOT remove approved — the PreToolUse hook (validate_plan_quality.sh) is the
# authoritative source. If the bundle is incomplete here, the PreToolUse already
# set the best state it could. Removing it would destroy a valid approval.
# Log a warning so the model can tell the user to /approve if needed.
allow_with_context "Plan approval metadata may be incomplete but was NOT removed. If edits are blocked, tell the user to type /approve to rebuild metadata." "PostToolUse"
