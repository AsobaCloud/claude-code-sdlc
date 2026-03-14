#!/bin/bash
# Called by /accept command — preflights or finalizes acceptance for the current plan.

set -euo pipefail

source "$(dirname "$0")/common.sh"
init_persist_dir

MODE="${1:---finalize}"
PLAN_HASH=$(current_plan_hash)

objective_gate_satisfied() {
    if ! objective_verification_required_for_current_plan; then
        return 0
    fi

    if objective_verified_for_current_plan; then
        return 0
    fi

    if user_bypass_for_current_plan; then
        return 0
    fi

    return 1
}

acceptance_needs_bypass() {
    if state_exists dirty; then
        return 0
    fi

    if ! objective_gate_satisfied; then
        return 0
    fi

    return 1
}

print_bypass_reasons() {
    local pending_note=""
    if validate_pending_for_current_plan; then
        pending_note=$(state_read validate_pending)
    fi

    echo "BLOCKED: Acceptance still requires a user bypass for the current plan."
    if state_exists dirty; then
        echo "Uncleared dirty state: $(state_read dirty)"
    fi
    if ! objective_gate_satisfied; then
        echo "The approved plan objective has not been verified for the current plan."
    fi
    if [[ -n "$pending_note" ]]; then
        echo "Pending manual validation: $pending_note"
    fi
}

if [[ "$MODE" == "--preflight" ]]; then
    if ! acceptance_needs_bypass; then
        state_remove accept_bypass_pending
        state_remove accept_bypass_pending_hash
        echo "Acceptance preflight passed."
        exit 0
    fi

    if accept_bypass_pending_for_current_plan; then
        state_write user_bypass "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        state_write user_bypass_hash "$PLAN_HASH"
        state_remove accept_bypass_pending
        state_remove accept_bypass_pending_hash
        echo "USER BYPASS CONFIRMED: proceeding without objective verification for the current plan."
        exit 0
    fi

    state_write accept_bypass_pending "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    state_write accept_bypass_pending_hash "$PLAN_HASH"
    print_bypass_reasons
    echo "If you personally verified the objective in the real system and want to bypass these remaining gates, run /accept again."
    exit 1
fi

if [[ "$MODE" != "--finalize" ]]; then
    echo "BLOCKED: Unsupported mode '$MODE'. Use --preflight or --finalize."
    exit 1
fi

if acceptance_needs_bypass && ! user_bypass_for_current_plan; then
    print_bypass_reasons
    echo "Run /accept again only if you want to manually bypass these remaining gates."
    exit 1
fi

# Display validation evidence before clearing
echo "── VALIDATION EVIDENCE ──"
VALIDATED_CONTENT=$(state_read validated)
if [[ -n "$VALIDATED_CONTENT" ]]; then
    echo "Last validation: $VALIDATED_CONTENT"
else
    echo "Last validation: (none recorded)"
fi
OBJ_EVIDENCE=$(state_read objective_verified_evidence)
USER_BYPASS_VAL=$(state_read user_bypass)
if [[ -n "$OBJ_EVIDENCE" ]]; then
    echo "Objective verification: $OBJ_EVIDENCE"
elif [[ -n "$USER_BYPASS_VAL" ]]; then
    echo "Objective verification: USER BYPASS ($USER_BYPASS_VAL)"
else
    echo "Objective verification: (not recorded)"
fi
VALIDATION_LOG=$(state_read validation_log)
if [[ -n "$VALIDATION_LOG" ]]; then
    echo ""
    echo "Validation log:"
    echo "$VALIDATION_LOG"
else
    echo "Validation log: (empty)"
fi
echo "─────────────────────────"

# Extract SEP reference and objective from plan before clearing
SEP_REF=""
OBJECTIVE_TEXT=""
OBJECTIVE_CONTENT=$(state_read objective)
if [[ -n "$OBJECTIVE_CONTENT" ]]; then
    SEP_REF=$(echo "$OBJECTIVE_CONTENT" | grep -oE 'SEP-[0-9]+' 2>/dev/null | head -1 || true)
    OBJECTIVE_TEXT=$(echo "$OBJECTIVE_CONTENT" | head -1)
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

    ENTRY=""
    if [[ -n "$SEP_REF" ]]; then
        ENTRY="- **${SEP_REF}**: ${OBJECTIVE_TEXT} — done (${COMMIT_HASH}, ${COMPLETED_AT})"
    else
        ENTRY="- ${OBJECTIVE_TEXT} — done (${COMMIT_HASH}, ${COMPLETED_AT})"
    fi

    if ! grep -q '^## Work Log' "$MEMORY_FILE"; then
        printf '\n## Work Log\n%s\n' "$ENTRY" >> "$MEMORY_FILE"
    else
        awk -v entry="$ENTRY" '
            /^## Work Log/ { print; found=1; next }
            found && /^## / { print entry; found=0 }
            { print }
            END { if (found) print entry }
        ' "$MEMORY_FILE" > "${MEMORY_FILE}.tmp" && mv "${MEMORY_FILE}.tmp" "$MEMORY_FILE"
    fi

    if [[ -n "$SEP_REF" ]]; then
        sed -i '' "/${SEP_REF}.*in-progress/d" "$MEMORY_FILE" 2>/dev/null || true
    fi

    echo "Memory updated: ${ENTRY}"
fi

# ── Mark plan file as completed ──
PLAN_FILE_PATH=$(state_read plan_file)
if [[ -n "$PLAN_FILE_PATH" ]]; then
    PLAN_FILE=$(echo "$PLAN_FILE_PATH" | tr -d '\r' | sed 's/^"//;s/"$//')
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

# Save last_sep_ref before clearing (survives plan cycles)
LAST_SEP_REF=""
if [[ -n "$SEP_REF" ]]; then
    LAST_SEP_REF="$SEP_REF"
fi

# Clear all conversation state
clear_all_state

# Restore last_sep_ref (persists across plan cycles)
if [[ -n "$LAST_SEP_REF" ]]; then
    state_write last_sep_ref "$LAST_SEP_REF"
fi

echo "Implementation accepted. Plan approval cleared. Ready for next task."
