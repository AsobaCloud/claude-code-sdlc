#!/bin/bash
# Validation recording tied to the approved plan objective.
#
# Usage:
#   ~/.claude/scripts/record_validation.sh --command "pytest -k smoke"
#       Verifies the command ran and, for code-change plans, that it matches
#       the approved ## Objective Verification section. Clears dirty and marks
#       the current plan objective as verified.
#
#   ~/.claude/scripts/record_validation.sh --manual "user must verify X"
#       Records that objective verification is pending manual user validation.
#       Does NOT clear dirty and does NOT bypass completion gates.

set -euo pipefail

source "$(dirname "$0")/common.sh"
init_persist_dir

MODE=""
DESCRIPTION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --command)
            MODE="command"
            shift
            if [[ $# -gt 0 ]]; then
                DESCRIPTION="$1"
                shift
            fi
            ;;
        --manual)
            MODE="manual"
            shift
            if [[ $# -gt 0 ]]; then
                DESCRIPTION="$1"
                shift
            fi
            ;;
        --force)
            echo "BLOCKED: Agent bypass is not permitted. --force has been removed."
            echo "Only the user may manually bypass missing objective verification."
            exit 1
            ;;
        *)
            DESCRIPTION="$1"
            shift
            ;;
    esac
done

DESCRIPTION="${DESCRIPTION:-}"
PLAN_HASH=$(current_plan_hash)
EDIT_COUNT=$(current_edit_count)
OBJECTIVE_VERIFICATION=$(state_read objective_verification)

if [[ -z "$MODE" ]]; then
    echo "BLOCKED: record_validation.sh requires a flag."
    echo ""
    echo "Usage:"
    echo "  --command \"cmd\"  Verify the approved objective-verification command ran"
    echo "  --manual \"desc\"  Record pending manual user verification"
    exit 1
fi

# Plan hash may be absent in test harness; allow --manual to proceed without an approved plan.

if [[ "$MODE" == "command" ]]; then
    if [[ -z "$DESCRIPTION" ]]; then
        echo "BLOCKED: --command requires a command string."
        exit 1
    fi

    LOG_CONTENT=$(state_read validation_log)
    if [[ -z "$LOG_CONTENT" ]] || ! echo "$LOG_CONTENT" | grep -Fq "$DESCRIPTION"; then
        echo "BLOCKED: Command '$DESCRIPTION' not found in validation_log."
        echo "Run the command first via Bash, then call record_validation.sh --command."
        exit 1
    fi

    if objective_verification_required_for_current_plan; then
        if [[ -z "$OBJECTIVE_VERIFICATION" ]] || ! echo "$OBJECTIVE_VERIFICATION" | grep -Fq "$DESCRIPTION"; then
            echo "BLOCKED: Command '$DESCRIPTION' is not approved in the current plan's ## Objective Verification section."
            exit 1
        fi
    fi

    state_remove dirty
    state_write objective_verified "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    state_write objective_verified_hash "$PLAN_HASH"
    state_write objective_verified_edit_count "$EDIT_COUNT"
    state_write objective_verified_evidence "$DESCRIPTION"
    log_event "objective_verified" "$DESCRIPTION"
    state_write validated "[OBJECTIVE VERIFIED] $DESCRIPTION"
    state_append validation_log "$(date -u +%Y-%m-%dT%H:%M:%SZ) [OBJECTIVE VERIFIED] $DESCRIPTION"

    state_remove validate_pending
    state_remove validate_pending_hash
    state_remove accept_bypass_pending
    state_remove accept_bypass_pending_hash
    state_remove user_bypass
    state_remove user_bypass_hash

    echo "Objective verification recorded for current plan: ${DESCRIPTION}. Dirty flag cleared."
    exit 0
fi

if [[ "$MODE" == "manual" ]]; then
    if [[ -z "$DESCRIPTION" ]]; then
        echo "BLOCKED: --manual requires a description."
        exit 1
    fi

    state_write validate_pending "[MANUAL PENDING] $DESCRIPTION"
    state_write validate_pending_hash "$PLAN_HASH"
    state_append validation_log "$(date -u +%Y-%m-%dT%H:%M:%SZ) [MANUAL PENDING] $DESCRIPTION"
    echo "Manual objective verification pending: ${DESCRIPTION}."
    echo "This does not complete the task. Only the user may manually bypass by invoking /accept after reviewing the missing proof."
    exit 0
fi

echo "BLOCKED: Unsupported mode '$MODE'."
exit 1
