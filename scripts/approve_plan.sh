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

# Store conversation token with approval (SEP-005)
CONV_TOKEN=$(read_conversation_token)
if [[ -n "$CONV_TOKEN" ]]; then
    state_write approval_token "$CONV_TOKEN"
fi

# Clean up planning state
state_remove planning
state_remove planning_started_at

if approval_bundle_is_complete; then
    allow_with_context "Plan approved. Editing unlocked. Implement ONLY the approved changes. When done, run ~/.claude/scripts/clear_approval.sh then tell the user to /accept or /reject." "PostToolUse"
fi

state_remove approved
allow_with_context "Plan approval metadata is incomplete. Re-run ExitPlanMode to rebuild scope/objective/criteria before editing." "PostToolUse"
