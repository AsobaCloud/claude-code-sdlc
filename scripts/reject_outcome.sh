#!/bin/bash
# Called by /reject command — clears approval after user rejects implementation

PROJECT_HASH=$(pwd | shasum | cut -c1-12)
PERSIST_DIR="${CLAUDE_TEST_PERSIST_DIR:-${HOME}/.claude/state/${PROJECT_HASH}}"

# Clear project state (including diagnostic_mode)
rm -f "${PERSIST_DIR}/approved" "${PERSIST_DIR}/objective" "${PERSIST_DIR}/scope" "${PERSIST_DIR}/criteria" "${PERSIST_DIR}/plan_file" "${PERSIST_DIR}/planning" "${PERSIST_DIR}/diagnostic_mode"

echo "Implementation rejected. Plan approval cleared. Provide feedback for re-planning."
