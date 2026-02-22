#!/bin/bash
# Called by /accept command — clears approval after user accepts implementation
# Works with both session and persistent state

PROJECT_HASH=$(pwd | shasum | cut -c1-12)
PERSIST_DIR="${CLAUDE_TEST_PERSIST_DIR:-${HOME}/.claude/state/${PROJECT_HASH}}"
HOOKS_DIR="${CLAUDE_TEST_HOOKS_DIR:-/tmp/.claude_hooks}"

# Before clearing state, extract SEP reference from objective for commit message
if [[ -f "${PERSIST_DIR}/objective" ]]; then
    SEP_REF=$(grep -oE 'SEP-[0-9]+' "${PERSIST_DIR}/objective" 2>/dev/null | head -1)
    if [[ -n "$SEP_REF" ]]; then
        echo "$SEP_REF" > "${PERSIST_DIR}/last_sep_ref"
    fi
fi

# Clear persistent state
rm -f "${PERSIST_DIR}/approved" "${PERSIST_DIR}/objective" "${PERSIST_DIR}/scope" "${PERSIST_DIR}/criteria" "${PERSIST_DIR}/context_injected" "${PERSIST_DIR}/planning" "${PERSIST_DIR}/explore_count" "${PERSIST_DIR}/exploration_log"

# Clear all active session states (we may not know which session we're in)
for D in "${HOOKS_DIR}"/*/; do
    [ -d "$D" ] || continue
    rm -f "${D}/approved" "${D}/objective" "${D}/scope" "${D}/criteria" "${D}/context_injected" "${D}/planning" "${D}/explore_count" "${D}/exploration_log"
done

echo "Implementation accepted. Plan approval cleared. Ready for next task."
