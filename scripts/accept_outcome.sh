#!/bin/bash
# Called by /accept command — preflights or finalizes acceptance for the current plan.

set -euo pipefail

source "$(dirname "$0")/common.sh"

PROJECT_HASH=$(pwd | shasum | cut -c1-12)
PERSIST_DIR="${CLAUDE_TEST_PERSIST_DIR:-${HOME}/.claude/state/${PROJECT_HASH}}"
mkdir -p "$PERSIST_DIR"

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
    if [[ -f "${PERSIST_DIR}/dirty" ]]; then
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
        pending_note=$(cat "${PERSIST_DIR}/validate_pending")
    fi

    echo "BLOCKED: Acceptance still requires a user bypass for the current plan."
    if [[ -f "${PERSIST_DIR}/dirty" ]]; then
        echo "Uncleared dirty state: $(cat "${PERSIST_DIR}/dirty")"
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
        rm -f "${PERSIST_DIR}/accept_bypass_pending" "${PERSIST_DIR}/accept_bypass_pending_hash"
        echo "Acceptance preflight passed."
        exit 0
    fi

    if accept_bypass_pending_for_current_plan; then
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${PERSIST_DIR}/user_bypass"
        echo "$PLAN_HASH" > "${PERSIST_DIR}/user_bypass_hash"
        rm -f "${PERSIST_DIR}/accept_bypass_pending" "${PERSIST_DIR}/accept_bypass_pending_hash"
        echo "USER BYPASS CONFIRMED: proceeding without objective verification for the current plan."
        exit 0
    fi

    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${PERSIST_DIR}/accept_bypass_pending"
    echo "$PLAN_HASH" > "${PERSIST_DIR}/accept_bypass_pending_hash"
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
if [[ -f "${PERSIST_DIR}/validated" ]]; then
    echo "Last validation: $(cat "${PERSIST_DIR}/validated")"
else
    echo "Last validation: (none recorded)"
fi
if [[ -f "${PERSIST_DIR}/objective_verified_evidence" ]]; then
    echo "Objective verification: $(cat "${PERSIST_DIR}/objective_verified_evidence")"
elif [[ -f "${PERSIST_DIR}/user_bypass" ]]; then
    echo "Objective verification: USER BYPASS ($(cat "${PERSIST_DIR}/user_bypass"))"
else
    echo "Objective verification: (not recorded)"
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
    SEP_REF=$(grep -oE 'SEP-[0-9]+' "${PERSIST_DIR}/objective" 2>/dev/null | head -1 || true)
    OBJECTIVE_TEXT=$(cat "${PERSIST_DIR}/objective" 2>/dev/null | head -1 || true)
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

# Clear project state
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

echo "Implementation accepted. Plan approval cleared. Ready for next task."
