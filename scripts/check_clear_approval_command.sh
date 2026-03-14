#!/bin/bash
# UserPromptSubmit hook — diagnostic mode detector + universal epistemics injector
# Fires on every user message. Two responsibilities:
# 1. Inject universal epistemics reminder on ALL messages
# 2. Detect diagnostic questions and enforce investigation mode
source "$(dirname "$0")/common.sh"
init_hook

# ── Extract user prompt ──
USER_PROMPT=$(echo "$HOOK_INPUT" | jq -r '.prompt // empty')

# ── Escape hatch: /skip-investigation ──
if echo "$USER_PROMPT" | grep -qi '/skip-investigation'; then
    state_remove diagnostic_mode
    jq -n '{
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": "Investigation mode skipped by user request. Proceed normally, but still prefer evidence over assumptions."
        }
    }'
    exit 0
fi

# ── Diagnostic pattern detection ──
# Broad matching — false positives acceptable, false negatives are the enemy
DIAGNOSTIC_PATTERN='(broken|down|failing|failed|error|not working|crashed|stuck|why is|what happened|debug|diagnose|troubleshoot|help.*(server|deploy|infra|cluster|database|service)|fucked|borked|wrong with|went wrong|stopped|can'\''t connect|connection refused|timeout|timed out|500|502|503|504|OOM|segfault|panic|logs? show|is it dead|health.?check|unreachable)'

IS_DIAGNOSTIC=false
if echo "$USER_PROMPT" | grep -qiE "$DIAGNOSTIC_PATTERN"; then
    IS_DIAGNOSTIC=true
fi

# ── Universal epistemics reminder (injected on every message) ──
UNIVERSAL_REMINDER="── EPISTEMICS REMINDER ──
Your training knowledge is an unreliable prior. Before making ANY factual claim:
• Corroborate with evidence from the actual codebase, docs, or runtime behavior.
• If you cannot find corroboration, say so explicitly — do not proceed on assumption.
• When evidence contradicts your assumption: STOP, discard the assumption, rebuild from evidence."

# ── Two-phase diagnostic blocking ──
# Don't trigger diagnostic mode during active implementation
if [[ "$IS_DIAGNOSTIC" == "true" ]] && state_exists approved; then
    IS_DIAGNOSTIC=false
fi

if [[ "$IS_DIAGNOSTIC" == "true" ]]; then
    if ! state_exists diagnostic_mode; then
        # Phase 1: First submission of a diagnostic question
        # Set state flag and BLOCK the prompt (erases it from context)
        state_write diagnostic_mode "1"
        jq -n --arg reason "$(cat <<'REASON'
⚠️ INVESTIGATION MODE: This looks like a diagnostic question.
Claude must investigate before making claims.

Re-submit your question to enter investigation mode.
Type /skip-investigation to bypass.
REASON
)" '{
            "hookSpecificOutput": {
                "hookEventName": "UserPromptSubmit",
                "decision": "block",
                "reason": $reason
            }
        }'
        exit 0
    fi
    # Phase 2: Re-submission — diagnostic_mode already set, allow through with directives
    DIAGNOSTIC_DIRECTIVE="── INVESTIGATION REQUIRED ──
This is a DIAGNOSTIC question. You MUST investigate before making ANY claims.

MANDATORY PROTOCOL:
1. Do NOT make any diagnostic claims, assessments, or reassurances yet.
2. Call EnterPlanMode IMMEDIATELY.
3. Write an investigation plan with:
   - ## Hypothesis: What might be wrong (with stated confidence levels)
   - ## Investigation Steps: Specific checks to run (commands, files, logs)
   - ## Scope: Systems/files/logs to examine
4. Get the plan approved via ExitPlanMode.
5. Execute the investigation systematically.
6. Present findings with evidence citations.

CRITICAL: Any tool use (Read, Grep, Bash, etc.) will be BLOCKED until you enter
plan mode and get an investigation plan approved. Only EnterPlanMode is available.

Do NOT say 'let me check' and then make claims. Do NOT offer preliminary assessments.
Your FIRST action must be calling EnterPlanMode."

    FULL_CONTEXT="${UNIVERSAL_REMINDER}

${DIAGNOSTIC_DIRECTIVE}"
elif state_exists diagnostic_mode; then
    # Non-diagnostic message but diagnostic_mode still active from previous turn
    DIAGNOSTIC_CONTINUATION="── DIAGNOSTIC MODE STILL ACTIVE ──
Investigation mode is still active from a previous diagnostic question.
Tools remain blocked until you complete the investigation plan workflow.
Enter plan mode, write an investigation plan, get it approved, then investigate.
Type /skip-investigation to exit investigation mode."

    FULL_CONTEXT="${UNIVERSAL_REMINDER}

${DIAGNOSTIC_CONTINUATION}"
else
    # Normal non-diagnostic message
    FULL_CONTEXT="$UNIVERSAL_REMINDER"
fi

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

    if [[ "$EDIT_COUNT" -gt 0 && -n "$PHASE_DETAIL" ]]; then
        PHASE_DETAIL="${PHASE_DETAIL}, edits: ${EDIT_COUNT}"
    elif [[ "$EDIT_COUNT" -gt 0 ]]; then
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
    WORKFLOW_STATE="${WORKFLOW_STATE}
Next: Continue implementing approved changes."

elif state_exists planning; then
    WORKFLOW_STATE="── WORKFLOW STATE ──
Session: ${SESSION_ID:-unknown}
Plan dir: $(conversation_plan_dir)
Phase: PLANNING (plan mode active)
Next: Write your plan to $(conversation_plan_dir)/<name>.md, then call ExitPlanMode to get it approved."
fi

# Append workflow state to context if present
if [[ -n "$WORKFLOW_STATE" ]]; then
    FULL_CONTEXT="${FULL_CONTEXT}

${WORKFLOW_STATE}"
fi

# ── Output: allow with context injection ──
jq -n --arg ctx "$FULL_CONTEXT" '{
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": $ctx
    }
}'
exit 0
