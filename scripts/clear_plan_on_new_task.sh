#!/bin/bash
# PostToolUse hook on EnterPlanMode — clears approval, enters planning
# All state is persist-only.
source "$(dirname "$0")/common.sh"
init_hook

# Clear all approval state
state_remove approved
state_remove objective
state_remove scope
state_remove criteria
state_remove objective_verification
state_remove objective_verification_required
state_remove plan_file
state_remove plan_hash
state_remove planning_started_at

# Clear validation state
state_remove dirty
state_remove validated
state_remove validation_log
state_remove validated_unit
state_remove validated_e2e
state_remove tests_failed
state_remove tests_reviewed
state_remove objective_verified
state_remove objective_verified_hash
state_remove objective_verified_edit_count
state_remove objective_verified_evidence
state_remove validate_pending
state_remove validate_pending_hash
state_remove accept_bypass_pending
state_remove accept_bypass_pending_hash
state_remove user_bypass
state_remove user_bypass_hash

# Enter planning mode
state_write planning "1"
state_write planning_started_at "$(date +%s)"

PLAN_DIR=$(conversation_plan_dir)
echo "Previous plan cleared. Write your plan to ${PLAN_DIR}/<name>.md. Read docs and code before writing a plan."
exit 0
