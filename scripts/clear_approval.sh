#!/bin/bash
# Clear plan approval — forces Claude back into plan mode
# Usage: ~/.claude/scripts/clear_approval.sh
# No args needed — uses current working directory

PROJECT_HASH=$(pwd | shasum | cut -c1-12)
PERSIST_DIR="${CLAUDE_TEST_PERSIST_DIR:-${HOME}/.claude/state/${PROJECT_HASH}}"

# Gate: block if unvalidated edits exist
if [[ -f "${PERSIST_DIR}/dirty" ]]; then
    echo "BLOCKED: Unvalidated edits exist. Run tests or call record_validation.sh before signaling completion."
    echo "Dirty since: $(cat "${PERSIST_DIR}/dirty")"
    exit 1
fi

# Clear all project state (including diagnostic_mode and validation state)
rm -f "${PERSIST_DIR}/approved" "${PERSIST_DIR}/objective" "${PERSIST_DIR}/scope" "${PERSIST_DIR}/criteria" "${PERSIST_DIR}/plan_file" "${PERSIST_DIR}/plan_hash" "${PERSIST_DIR}/planning" "${PERSIST_DIR}/planning_started_at" "${PERSIST_DIR}/diagnostic_mode" "${PERSIST_DIR}/dirty" "${PERSIST_DIR}/validated" "${PERSIST_DIR}/validation_log" "${PERSIST_DIR}/validated_unit" "${PERSIST_DIR}/validated_e2e"

echo "Approval cleared for project (hash: ${PROJECT_HASH}). Claude must now plan before editing."
