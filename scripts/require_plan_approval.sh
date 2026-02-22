#!/bin/bash
# PreToolUse hook on Edit|Write|NotebookEdit — blocks until plan approved
source "$(dirname "$0")/common.sh"
init_hook

FILE_PATH=$(tool_input file_path)
[[ -z "$FILE_PATH" ]] && FILE_PATH=$(tool_input notebook_path)

# Always allow writes to: plan files, SEP files, Claude memory files
if [[ "$FILE_PATH" == *"/.claude/plans/"* ]]; then
    exit 0
fi
if [[ "$FILE_PATH" == *"/.sep/"* ]]; then
    exit 0
fi
if [[ "$FILE_PATH" == *"/.claude/projects/"*"/memory/"* ]]; then
    exit 0
fi

# ── Check approval ──
if ! state_exists approved; then
    EXISTING_PLAN=""
    for pf in "${HOME}/.claude/plans/"*.md; do
        [[ -f "$pf" ]] && EXISTING_PLAN="$pf" && break
    done

    if [[ -n "$EXISTING_PLAN" ]]; then
        deny_tool "BLOCKED: No approved plan for this work.

A plan file exists at: ${EXISTING_PLAN}

NEXT ACTION: Call ExitPlanMode to get it approved.
If you need a different plan, call EnterPlanMode first."
    else
        deny_tool "BLOCKED: No approved plan for this work.

NEXT ACTION: Call EnterPlanMode to start planning.
Then: explore code → write plan → call ExitPlanMode for approval.

If you already had approval, ask the user to type /approve."
    fi
fi

# ── Scope enforcement (fail-closed) ──
if state_exists scope; then
    SCOPE_CONTENT=$(state_read scope)

    # Empty scope file = fail closed (block everything)
    if [[ -z "$SCOPE_CONTENT" ]]; then
        deny_tool "BLOCKED: Scope file exists but is empty — cannot verify file is in scope.
Re-run your plan with a valid ## Scope section listing files to modify."
    fi

    IN_SCOPE=false
    while IFS= read -r SCOPE_PATH; do
        [[ -z "$SCOPE_PATH" ]] && continue
        local_expanded="${SCOPE_PATH/#\~/$HOME}"
        # Exact match
        [[ "$FILE_PATH" == "$local_expanded" ]] && IN_SCOPE=true && break
        # File ends with scope path
        [[ "$FILE_PATH" == *"$SCOPE_PATH" ]] && IN_SCOPE=true && break
        # Scope is directory prefix
        [[ "$FILE_PATH" == "${local_expanded}"* ]] && IN_SCOPE=true && break
    done <<< "$SCOPE_CONTENT"

    if [[ "$IN_SCOPE" == "false" ]]; then
        deny_tool "BLOCKED: File not in approved scope.

File: $FILE_PATH

Approved scope:
$(echo "$SCOPE_CONTENT" | sed 's/^/  - /')

To modify this file, update your plan's ## Scope section and get re-approval."
    fi
fi

# ── Context injection (every edit) ──
EDIT_COUNT=$(counter_increment edit_count)

CONTEXT=""
if state_exists objective; then
    CONTEXT+="── OBJECTIVE ──
$(state_read objective)
"
fi
if state_exists scope; then
    CONTEXT+="── SCOPE (only these files may be edited) ──
$(state_read scope)
"
fi
if state_exists criteria; then
    CONTEXT+="── SUCCESS CRITERIA ──
$(state_read criteria)
"
fi
CONTEXT+="── CONSTRAINT ──
Edit #${EDIT_COUNT}. ONLY make changes described in the approved plan. When implementation is complete, run: ~/.claude/scripts/clear_approval.sh — then tell the user to /accept or /reject. Do NOT make additional edits after signaling completion.
"

if [[ -n "$CONTEXT" ]]; then
    allow_with_context "$CONTEXT"
fi
