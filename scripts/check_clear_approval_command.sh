#!/bin/bash
# UserPromptSubmit hook — universal epistemics injector + workflow state reporter
# Fires on every user message. Responsibilities:
# 1. Inject universal epistemics reminder on ALL messages
# 2. Inject workflow state (approved plan, planning phase) for compaction recovery
source "$(dirname "$0")/common.sh"
init_hook

# ── Universal epistemics reminder (injected on every message) ──
UNIVERSAL_REMINDER="── EPISTEMICS REMINDER ──
Your training knowledge is an unreliable prior. Before making ANY factual claim:
• Corroborate with evidence from the actual codebase, docs, or runtime behavior.
• If you cannot find corroboration, say so explicitly — do not proceed on assumption.
• When evidence contradicts your assumption: STOP, discard the assumption, rebuild from evidence."

FULL_CONTEXT="$UNIVERSAL_REMINDER"

# ── Workflow state injection (SEP-006) ──
# Build a state summary from persistent markers so the model stays oriented after compaction.
WORKFLOW_STATE=""

if state_exists approved; then
    OBJECTIVE=$(state_read objective)
    SCOPE=$(state_read scope)
    CRITERIA=$(state_read criteria)
    PLAN_FILE_PATH=$(state_read plan_file)
    EDIT_COUNT=$(state_read edit_count)
    [[ "$EDIT_COUNT" =~ ^[0-9]+$ ]] || EDIT_COUNT=0

    # Determine TDD phase
    PHASE="APPROVED"
    PHASE_DETAIL=""
    if state_exists tests_failed; then
        if state_exists tests_reviewed; then
            PHASE="IMPLEMENTING"
            PHASE_DETAIL="tests written ✓, tests reviewed ✓"
        else
            PHASE="TESTS WRITTEN (red phase)"
            PHASE_DETAIL="tests failed ✓, awaiting /approve-tests"
        fi
    fi

    # VERIFYING phase: validation_complete set but objective not yet verified
    IS_VERIFYING=false
    if state_exists validation_complete && ! state_exists dirty; then
        if ! objective_verified_for_current_plan; then
            IS_VERIFYING=true
            PHASE="VERIFYING"
            PHASE_DETAIL="two-tier validation complete ✓, awaiting /verify"
        fi
    fi

    if [[ "$EDIT_COUNT" -gt 0 && -n "$PHASE_DETAIL" && "$IS_VERIFYING" == "false" ]]; then
        PHASE_DETAIL="${PHASE_DETAIL}, edits: ${EDIT_COUNT}"
    elif [[ "$EDIT_COUNT" -gt 0 && "$IS_VERIFYING" == "false" ]]; then
        PHASE_DETAIL="edits: ${EDIT_COUNT}"
    fi

    # Dirty / validation status
    VALIDATION_STATUS=""
    if state_exists dirty; then
        VALIDATION_STATUS="⚠ Validation needed (dirty — edits made but not validated)"
    fi

    # Build the block
    WORKFLOW_STATE="── WORKFLOW STATE ──
Session: ${SESSION_ID:-unknown}
Plan dir: $(conversation_plan_dir)
Plan: APPROVED | objective: \"${OBJECTIVE}\"
Phase: ${PHASE}"
    [[ -n "$PHASE_DETAIL" ]] && WORKFLOW_STATE="${WORKFLOW_STATE} (${PHASE_DETAIL})"
    [[ -n "$PLAN_FILE_PATH" ]] && WORKFLOW_STATE="${WORKFLOW_STATE}
Plan file: ${PLAN_FILE_PATH}"
    [[ -n "$SCOPE" ]] && WORKFLOW_STATE="${WORKFLOW_STATE}
Scope: ${SCOPE}"
    [[ -n "$CRITERIA" ]] && WORKFLOW_STATE="${WORKFLOW_STATE}
Success criteria: ${CRITERIA}"
    [[ -n "$VALIDATION_STATUS" ]] && WORKFLOW_STATE="${WORKFLOW_STATE}
${VALIDATION_STATUS}"
    if [[ "$IS_VERIFYING" == "true" ]]; then
        WORKFLOW_STATE="${WORKFLOW_STATE}
Next: Invoke /verify to run acceptance checks."
    elif ! state_exists tests_failed; then
        WORKFLOW_STATE="${WORKFLOW_STATE}
Next: Invoke /tdd to begin TDD workflow."
    else
        WORKFLOW_STATE="${WORKFLOW_STATE}
Next: Continue implementing approved changes."
    fi

elif state_exists planning; then
    PREV_OBJ=$(state_read previous_objective)
    PREV_PLAN=$(state_read previous_plan_file)
    # If breadcrumb keys are empty, query plans table for richer context
    if [[ -z "$PREV_OBJ" ]]; then
        prev_row=""
        prev_row=$(get_previous_plan 2>/dev/null || true)
        if [[ -n "$prev_row" ]]; then
            PREV_PLAN=$(echo "$prev_row" | cut -d'|' -f2)
            # Extract objective from stored plan content
            prev_content=""
            prev_content=$(echo "$prev_row" | cut -d'|' -f3)
            if [[ -n "$prev_content" ]]; then
                PREV_OBJ=$(echo "$prev_content" | sed -n '/^##[[:space:]]*[Oo]bjective/,/^##/p' | tail -n +2 | grep -v '^## ' | sed '/^[[:space:]]*$/d' | head -1)
            fi
        fi
    fi
    # Find current draft if one exists
    CURRENT_DRAFT=""
    PLANNING_STARTED=$(state_read planning_started_at)
    if [[ "$PLANNING_STARTED" =~ ^[0-9]+$ && "$PLANNING_STARTED" -gt 0 ]]; then
        CURRENT_DRAFT=$(newest_plan_file "$PLANNING_STARTED" 2>/dev/null || true)
    fi
    [[ -z "$CURRENT_DRAFT" ]] && CURRENT_DRAFT=$(newest_plan_file 0 2>/dev/null || true)

    WORKFLOW_STATE="── WORKFLOW STATE ──
Session: ${SESSION_ID:-unknown}
Plan dir: $(conversation_plan_dir)
Phase: PLANNING (plan mode active)"
    [[ -n "$PREV_OBJ" ]] && WORKFLOW_STATE="${WORKFLOW_STATE}
Previously working on: ${PREV_OBJ}"
    [[ -n "$PREV_PLAN" ]] && WORKFLOW_STATE="${WORKFLOW_STATE}
Previous plan: ${PREV_PLAN}"
    [[ -n "$CURRENT_DRAFT" ]] && WORKFLOW_STATE="${WORKFLOW_STATE}
Current draft: ${CURRENT_DRAFT}"
    WORKFLOW_STATE="${WORKFLOW_STATE}
Next: Write or continue your plan, then call ExitPlanMode."
fi

# ── Compaction detection and recovery (SEP-027, SEP-028) ──
if state_exists compaction_detected; then
    COMPACTION_RECOVERY="── COMPACTION DETECTED ──
Context compaction occurred. Recovering workflow state from snapshot."

    # Read snapshot data (SEP-028)
    SNAPSHOT_DATA=$(state_read compaction_snapshot)
    if [[ -n "$SNAPSHOT_DATA" ]]; then
        COMPACTION_RECOVERY="${COMPACTION_RECOVERY}

${SNAPSHOT_DATA}"
    fi

    # Read and inject condensed plan content (SEP-028)
    RECOVERY_PLAN_FILE=$(state_read plan_file)
    if [[ -n "$RECOVERY_PLAN_FILE" && -f "$RECOVERY_PLAN_FILE" ]]; then
        PLAN_OBJECTIVE=$(extract_plan_objective "$RECOVERY_PLAN_FILE" | head -3)
        PLAN_SCOPE=$(extract_plan_scope "$RECOVERY_PLAN_FILE")
        PLAN_CRITERIA=$(extract_plan_criteria "$RECOVERY_PLAN_FILE" | head -3)
        PLAN_OBJ_VERIFY=$(extract_plan_objective_verification "$RECOVERY_PLAN_FILE" | head -5)

        COMPACTION_RECOVERY="${COMPACTION_RECOVERY}

── PLAN CONTENT (condensed) ──
Plan file: ${RECOVERY_PLAN_FILE}"
        [[ -n "$PLAN_OBJECTIVE" ]] && COMPACTION_RECOVERY="${COMPACTION_RECOVERY}
Objective: ${PLAN_OBJECTIVE}"
        [[ -n "$PLAN_SCOPE" ]] && COMPACTION_RECOVERY="${COMPACTION_RECOVERY}
Scope: ${PLAN_SCOPE}"
        [[ -n "$PLAN_CRITERIA" ]] && COMPACTION_RECOVERY="${COMPACTION_RECOVERY}
Success criteria: ${PLAN_CRITERIA}"
        [[ -n "$PLAN_OBJ_VERIFY" ]] && COMPACTION_RECOVERY="${COMPACTION_RECOVERY}
Objective verification: ${PLAN_OBJ_VERIFY}"
    fi

    # Determine phase for logging
    COMPACTION_PHASE="idle"
    if state_exists approved; then
        COMPACTION_PHASE="approved"
    elif state_exists planning; then
        COMPACTION_PHASE="planning"
    fi

    # Prepend recovery block to workflow state
    if [[ -n "$WORKFLOW_STATE" ]]; then
        WORKFLOW_STATE="${COMPACTION_RECOVERY}

${WORKFLOW_STATE}"
    else
        WORKFLOW_STATE="${COMPACTION_RECOVERY}"
    fi

    # Clear single-use flag and log
    state_remove compaction_detected
    log_event "state_injected_compaction_recovery" "phase=${COMPACTION_PHASE}"
else
    # Normal injection logging (SEP-025)
    if state_exists approved; then
        INJECT_PHASE="${PHASE:-APPROVED}"
        INJECT_EDITS="${EDIT_COUNT:-0}"
        log_event "state_injected_approved" "phase=${INJECT_PHASE} edits=${INJECT_EDITS}"
    elif [[ -z "$WORKFLOW_STATE" ]]; then
        log_event "state_injected_idle" ""
    fi
fi

# Append workflow state to context if present
if [[ -n "$WORKFLOW_STATE" ]]; then
    FULL_CONTEXT="${FULL_CONTEXT}

${WORKFLOW_STATE}"
fi

# ── Inject learned patterns from memories table with tiered attention ──
ensure_db
INJECTED_IDS=""
PATTERNS=$(db_query "SELECT id || '|' || title || '|' || REPLACE(SUBSTR(content, 1, 200), CHAR(10), ' ') || '|' || COALESCE(attention_score, 0.5) FROM memories ORDER BY (correction_count * 2.0) + (COALESCE(attention_score, 0.5) * 3.0) + (access_count * 0.1) DESC LIMIT 10;" 2>/dev/null || true)
if [[ -n "$PATTERNS" ]]; then
    LEARNED_BLOCK="── LEARNED PATTERNS ──"
    while IFS='|' read -r mem_id mem_title mem_rule mem_attn; do
        [[ -z "$mem_title" ]] && continue
        # Tiered rendering based on attention_score
        if (( $(echo "$mem_attn >= 0.7" | bc -l 2>/dev/null || echo 1) )); then
            # HOT: full content snippet
            LEARNED_BLOCK="${LEARNED_BLOCK}
• ${mem_title}: ${mem_rule}"
            INJECTED_IDS="${INJECTED_IDS}'$(sql_escape "$mem_id")',"
        elif (( $(echo "$mem_attn >= 0.25" | bc -l 2>/dev/null || echo 1) )); then
            # WARM: title only
            LEARNED_BLOCK="${LEARNED_BLOCK}
• ${mem_title}"
            INJECTED_IDS="${INJECTED_IDS}'$(sql_escape "$mem_id")',"
        fi
        # COLD (<0.25): omitted
    done <<< "$PATTERNS"
    FULL_CONTEXT="${FULL_CONTEXT}

${LEARNED_BLOCK}"
    # Boost attention_score and access_count for injected memories
    if [[ -n "$INJECTED_IDS" ]]; then
        INJECTED_IDS="${INJECTED_IDS%,}"  # trim trailing comma
        db_exec "UPDATE memories SET access_count = access_count + 1, attention_score = MIN(1.0, COALESCE(attention_score, 0.5) + 0.15), last_accessed = CAST(strftime('%s','now') AS INTEGER) WHERE id IN ($INJECTED_IDS);" 2>/dev/null || true
    fi
fi

# ── Output: allow with context injection ──
jq -n --arg ctx "$FULL_CONTEXT" '{
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": $ctx
    }
}'
exit 0
