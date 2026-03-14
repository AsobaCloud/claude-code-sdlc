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

PROJECT_HASH=$(pwd | shasum | cut -c1-12)
PERSIST_DIR="${CLAUDE_TEST_PERSIST_DIR:-${HOME}/.claude/state/${PROJECT_HASH}}"
mkdir -p "$PERSIST_DIR"

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
LOG_FILE="${PERSIST_DIR}/validation_log"

if [[ -z "$MODE" ]]; then
    echo "BLOCKED: record_validation.sh requires a flag."
    echo ""
    echo "Usage:"
    echo "  --command \"cmd\"  Verify the approved objective-verification command ran"
    echo "  --manual \"desc\"  Record pending manual user verification"
    exit 1
fi

if [[ -z "$PLAN_HASH" ]]; then
    echo "BLOCKED: No approved plan hash found. Re-approve the plan before recording validation."
    exit 1
fi

if [[ "$MODE" == "command" ]]; then
    if [[ -z "$DESCRIPTION" ]]; then
        echo "BLOCKED: --command requires a command string."
        exit 1
    fi

    if [[ ! -f "$LOG_FILE" ]] || ! grep -Fq "$DESCRIPTION" "$LOG_FILE"; then
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

    rm -f "${PERSIST_DIR}/dirty"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${PERSIST_DIR}/objective_verified"
    echo "$PLAN_HASH" > "${PERSIST_DIR}/objective_verified_hash"
    echo "$EDIT_COUNT" > "${PERSIST_DIR}/objective_verified_edit_count"
    echo "$DESCRIPTION" > "${PERSIST_DIR}/objective_verified_evidence"
    echo "[OBJECTIVE VERIFIED] $DESCRIPTION" > "${PERSIST_DIR}/validated"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [OBJECTIVE VERIFIED] $DESCRIPTION" >> "$LOG_FILE"

    rm -f "${PERSIST_DIR}/validate_pending" "${PERSIST_DIR}/validate_pending_hash"
    rm -f "${PERSIST_DIR}/accept_bypass_pending" "${PERSIST_DIR}/accept_bypass_pending_hash"
    rm -f "${PERSIST_DIR}/user_bypass" "${PERSIST_DIR}/user_bypass_hash"

    echo "Objective verification recorded for current plan: ${DESCRIPTION}. Dirty flag cleared."
    exit 0
fi

if [[ "$MODE" == "manual" ]]; then
    if [[ -z "$DESCRIPTION" ]]; then
        echo "BLOCKED: --manual requires a description."
        exit 1
    fi

    echo "[MANUAL PENDING] $DESCRIPTION" > "${PERSIST_DIR}/validate_pending"
    echo "$PLAN_HASH" > "${PERSIST_DIR}/validate_pending_hash"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [MANUAL PENDING] $DESCRIPTION" >> "$LOG_FILE"
    echo "Manual objective verification pending: ${DESCRIPTION}."
    echo "This does not complete the task. Only the user may manually bypass by invoking /accept after reviewing the missing proof."
    exit 0
fi

echo "BLOCKED: Unsupported mode '$MODE'."
exit 1
