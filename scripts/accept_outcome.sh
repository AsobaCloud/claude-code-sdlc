#!/bin/bash
# Called by /accept command — clears approval after user accepts implementation

PROJECT_HASH=$(pwd | shasum | cut -c1-12)
PERSIST_DIR="${CLAUDE_TEST_PERSIST_DIR:-${HOME}/.claude/state/${PROJECT_HASH}}"

# Gate: block if unvalidated edits exist
if [[ -f "${PERSIST_DIR}/dirty" ]]; then
    echo "BLOCKED: Unvalidated edits exist. Run tests or call record_validation.sh before accepting."
    echo "Dirty since: $(cat "${PERSIST_DIR}/dirty")"
    exit 1
fi

# Display validation evidence before clearing
echo "── VALIDATION EVIDENCE ──"
if [[ -f "${PERSIST_DIR}/validated" ]]; then
    echo "Last validation: $(cat "${PERSIST_DIR}/validated")"
else
    echo "Last validation: (none recorded)"
fi
if [[ -f "${PERSIST_DIR}/validation_log" ]]; then
    echo ""
    echo "Validation log:"
    cat "${PERSIST_DIR}/validation_log"
else
    echo "Validation log: (empty)"
fi
echo "─────────────────────────"

# Extract SEP reference from objective before clearing (for commit messages)
if [[ -f "${PERSIST_DIR}/objective" ]]; then
    SEP_REF=$(grep -oE 'SEP-[0-9]+' "${PERSIST_DIR}/objective" 2>/dev/null | head -1)
    if [[ -n "$SEP_REF" ]]; then
        echo "$SEP_REF" > "${PERSIST_DIR}/last_sep_ref"
    fi
fi

# Clear project state (including diagnostic_mode and validation state)
rm -f "${PERSIST_DIR}/approved" "${PERSIST_DIR}/objective" "${PERSIST_DIR}/scope" "${PERSIST_DIR}/criteria" "${PERSIST_DIR}/plan_file" "${PERSIST_DIR}/plan_hash" "${PERSIST_DIR}/planning" "${PERSIST_DIR}/planning_started_at" "${PERSIST_DIR}/diagnostic_mode" "${PERSIST_DIR}/dirty" "${PERSIST_DIR}/validated" "${PERSIST_DIR}/validation_log" "${PERSIST_DIR}/validated_unit" "${PERSIST_DIR}/validated_e2e" "${PERSIST_DIR}/tests_failed"

echo "Implementation accepted. Plan approval cleared. Ready for next task."
