#!/bin/bash
# Clear plan approval — forces Claude back into plan mode once validation is complete.

set -euo pipefail

source "$(dirname "$0")/common.sh"

PROJECT_HASH=$(pwd | shasum | cut -c1-12)
PERSIST_DIR="${CLAUDE_TEST_PERSIST_DIR:-${HOME}/.claude/state/${PROJECT_HASH}}"
mkdir -p "$PERSIST_DIR"

if [[ -f "${PERSIST_DIR}/dirty" ]]; then
    echo "BLOCKED: Unvalidated edits exist. Run the approved objective verification before signaling completion."
    echo "Dirty since: $(cat "${PERSIST_DIR}/dirty")"
    exit 1
fi

if objective_verification_required_for_current_plan && ! objective_verified_for_current_plan; then
    echo "BLOCKED: The approved plan objective has not been verified for the current plan."
    echo "Run the approved end-to-end verification and record it with:"
    echo "  ~/.claude/scripts/record_validation.sh --command \"<approved verification command>\""
    echo "If proof cannot be recorded, report objective unverified and stop. Only the user may bypass via /accept."
    exit 1
fi

rm -f \
    "${PERSIST_DIR}/approved" \
    "${PERSIST_DIR}/objective" \
    "${PERSIST_DIR}/scope" \
    "${PERSIST_DIR}/criteria" \
    "${PERSIST_DIR}/objective_verification" \
    "${PERSIST_DIR}/objective_verification_required" \
    "${PERSIST_DIR}/plan_file" \
    "${PERSIST_DIR}/plan_hash" \
    "${PERSIST_DIR}/planning" \
    "${PERSIST_DIR}/planning_started_at" \
    "${PERSIST_DIR}/diagnostic_mode" \
    "${PERSIST_DIR}/dirty" \
    "${PERSIST_DIR}/validated" \
    "${PERSIST_DIR}/validation_log" \
    "${PERSIST_DIR}/validated_unit" \
    "${PERSIST_DIR}/validated_e2e" \
    "${PERSIST_DIR}/tests_failed" \
    "${PERSIST_DIR}/tests_reviewed" \
    "${PERSIST_DIR}/approval_token" \
    "${PERSIST_DIR}/objective_verified" \
    "${PERSIST_DIR}/objective_verified_hash" \
    "${PERSIST_DIR}/objective_verified_edit_count" \
    "${PERSIST_DIR}/objective_verified_evidence" \
    "${PERSIST_DIR}/validate_pending" \
    "${PERSIST_DIR}/validate_pending_hash" \
    "${PERSIST_DIR}/accept_bypass_pending" \
    "${PERSIST_DIR}/accept_bypass_pending_hash" \
    "${PERSIST_DIR}/user_bypass" \
    "${PERSIST_DIR}/user_bypass_hash"

echo "Approval cleared for project (hash: ${PROJECT_HASH}). Claude must now plan before editing."
