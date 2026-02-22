#!/bin/bash
# Called by /accept command — clears approval after user accepts implementation

PROJECT_HASH=$(pwd | shasum | cut -c1-12)
PERSIST_DIR="${CLAUDE_TEST_PERSIST_DIR:-${HOME}/.claude/state/${PROJECT_HASH}}"

# Extract SEP reference from objective before clearing (for commit messages)
if [[ -f "${PERSIST_DIR}/objective" ]]; then
    SEP_REF=$(grep -oE 'SEP-[0-9]+' "${PERSIST_DIR}/objective" 2>/dev/null | head -1)
    if [[ -n "$SEP_REF" ]]; then
        echo "$SEP_REF" > "${PERSIST_DIR}/last_sep_ref"
    fi
fi

# Clear project state
rm -f "${PERSIST_DIR}/approved" "${PERSIST_DIR}/objective" "${PERSIST_DIR}/scope" "${PERSIST_DIR}/criteria" "${PERSIST_DIR}/plan_file" "${PERSIST_DIR}/planning"

echo "Implementation accepted. Plan approval cleared. Ready for next task."
