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

# Extract SEP reference and objective from plan before clearing
SEP_REF=""
OBJECTIVE_TEXT=""
if [[ -f "${PERSIST_DIR}/objective" ]]; then
    SEP_REF=$(grep -oE 'SEP-[0-9]+' "${PERSIST_DIR}/objective" 2>/dev/null | head -1)
    OBJECTIVE_TEXT=$(cat "${PERSIST_DIR}/objective" 2>/dev/null | head -1)
    if [[ -n "$SEP_REF" ]]; then
        echo "$SEP_REF" > "${PERSIST_DIR}/last_sep_ref"
    fi
fi

# ── Auto-update memory with completion record ──
COMMIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
COMPLETED_AT=$(date '+%Y-%m-%d')

# Find project memory directory
PWD_ESCAPED=$(pwd | sed 's|/|-|g')
MEMORY_DIR=""
for candidate in "${HOME}/.claude/projects/${PWD_ESCAPED}/memory"; do
    if [[ -d "$candidate" ]]; then
        MEMORY_DIR="$candidate"
        break
    fi
done
# Fallback: search for any matching memory dir
if [[ -z "$MEMORY_DIR" ]]; then
    for candidate in "${HOME}/.claude/projects/"*"/memory"; do
        if [[ -d "$candidate" ]]; then
            MEMORY_DIR="$candidate"
            break
        fi
    done
fi

if [[ -n "$MEMORY_DIR" && -f "${MEMORY_DIR}/MEMORY.md" ]]; then
    MEMORY_FILE="${MEMORY_DIR}/MEMORY.md"

    # Build the completion entry
    ENTRY=""
    if [[ -n "$SEP_REF" ]]; then
        ENTRY="- **${SEP_REF}**: ${OBJECTIVE_TEXT} — done (${COMMIT_HASH}, ${COMPLETED_AT})"
    else
        ENTRY="- ${OBJECTIVE_TEXT} — done (${COMMIT_HASH}, ${COMPLETED_AT})"
    fi

    # Ensure Work Log section exists, append entry
    if ! grep -q '^## Work Log' "$MEMORY_FILE"; then
        printf '\n## Work Log\n%s\n' "$ENTRY" >> "$MEMORY_FILE"
    else
        # Append after the Work Log header (before next ## or EOF)
        awk -v entry="$ENTRY" '
            /^## Work Log/ { print; found=1; next }
            found && /^## / { print entry; found=0 }
            { print }
            END { if (found) print entry }
        ' "$MEMORY_FILE" > "${MEMORY_FILE}.tmp" && mv "${MEMORY_FILE}.tmp" "$MEMORY_FILE"
    fi

    # Remove any "in-progress" entry for this SEP
    if [[ -n "$SEP_REF" ]]; then
        sed -i '' "/${SEP_REF}.*in-progress/d" "$MEMORY_FILE" 2>/dev/null || true
    fi

    echo "Memory updated: ${ENTRY}"
fi

# ── Mark plan file as completed ──
if [[ -f "${PERSIST_DIR}/plan_file" ]]; then
    PLAN_FILE=$(cat "${PERSIST_DIR}/plan_file" | tr -d '\r' | sed 's/^"//;s/"$//')
    if [[ -n "$PLAN_FILE" && -f "$PLAN_FILE" ]]; then
        if ! head -3 "$PLAN_FILE" | grep -q '^\*\*Status: DONE\*\*'; then
            {
                echo "**Status: DONE** — Completed ${COMPLETED_AT} (${COMMIT_HASH})"
                echo ""
                cat "$PLAN_FILE"
            } > "${PLAN_FILE}.tmp" && mv "${PLAN_FILE}.tmp" "$PLAN_FILE"
            echo "Plan marked as completed: $(basename "$PLAN_FILE")"
        fi
    fi
fi

# Clear project state (including diagnostic_mode and validation state)
rm -f "${PERSIST_DIR}/approved" "${PERSIST_DIR}/objective" "${PERSIST_DIR}/scope" "${PERSIST_DIR}/criteria" "${PERSIST_DIR}/plan_file" "${PERSIST_DIR}/plan_hash" "${PERSIST_DIR}/planning" "${PERSIST_DIR}/planning_started_at" "${PERSIST_DIR}/diagnostic_mode" "${PERSIST_DIR}/dirty" "${PERSIST_DIR}/validated" "${PERSIST_DIR}/validation_log" "${PERSIST_DIR}/validated_unit" "${PERSIST_DIR}/validated_e2e" "${PERSIST_DIR}/tests_failed"

echo "Implementation accepted. Plan approval cleared. Ready for next task."
