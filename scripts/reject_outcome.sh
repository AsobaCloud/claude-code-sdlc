#!/bin/bash
# Called by /reject command — clears approval after user rejects implementation

set -euo pipefail

PROJECT_HASH=$(pwd | shasum | cut -c1-12)
PERSIST_DIR="${CLAUDE_TEST_PERSIST_DIR:-${HOME}/.claude/state/${PROJECT_HASH}}"

# Clear project state (including diagnostic_mode and validation state)
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

echo "Implementation rejected. Plan approval cleared. Provide feedback for re-planning."
