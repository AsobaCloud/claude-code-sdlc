#!/bin/bash
# Clear plan approval — forces Claude back into plan mode once validation is complete.

set -euo pipefail

source "$(dirname "$0")/common.sh"
init_persist_dir

if state_exists dirty; then
    echo "BLOCKED: Unvalidated edits exist. Run the approved objective verification before signaling completion."
    echo "Dirty since: $(state_read dirty)"
    exit 1
fi

if objective_verification_required_for_current_plan && ! objective_verified_for_current_plan; then
    echo "BLOCKED: The approved plan objective has not been verified for the current plan."
    echo "Run the approved end-to-end verification and record it with:"
    echo "  ~/.claude/scripts/record_validation.sh --command \"<approved verification command>\""
    echo "If proof cannot be recorded, report objective unverified and stop. Only the user may bypass via /accept."
    exit 1
fi

clear_workflow_keys
clear_plan_context_keys

echo "Approval cleared for project (hash: ${PROJECT_HASH}). Claude must now plan before editing."
