#!/bin/bash
# Clear plan approval — forces Claude back into plan mode
# Usage: ~/.claude/scripts/clear_approval.sh
# No args needed — uses current working directory

PROJECT_HASH=$(pwd | shasum | cut -c1-12)
PERSIST_DIR="${CLAUDE_TEST_PERSIST_DIR:-${HOME}/.claude/state/${PROJECT_HASH}}"

# Clear all project state (including diagnostic_mode)
rm -f "${PERSIST_DIR}/approved" "${PERSIST_DIR}/objective" "${PERSIST_DIR}/scope" "${PERSIST_DIR}/criteria" "${PERSIST_DIR}/plan_file" "${PERSIST_DIR}/planning" "${PERSIST_DIR}/diagnostic_mode"

echo "Approval cleared for project (hash: ${PROJECT_HASH}). Claude must now plan before editing."
