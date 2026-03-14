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

NEXT ACTION: Call ExitPlanMode now. Do NOT call EnterPlanMode — that will delete this plan."
    else
        deny_tool "BLOCKED: No approved plan for this work.

No plan file exists — you must create one.

NEXT ACTION: Call EnterPlanMode now. Then write a plan to ~/.claude/plans/<name>.md, then call ExitPlanMode."
    fi
fi

# ── Approval metadata integrity checks (fail-closed) ──
METADATA_ERRORS=""
PLAN_FILE=$(normalize_plan_path "$(state_read plan_file)")
SCOPE_CONTENT=$(state_read scope)
APPROVED_PLAN_HASH=$(state_read plan_hash)
OBJECTIVE_VERIFICATION_REQUIRED=$(state_read objective_verification_required)
OBJECTIVE_VERIFICATION=$(state_read objective_verification)

if [[ -z "$PLAN_FILE" ]]; then
    METADATA_ERRORS+="  - Missing plan_file marker.
"
elif [[ ! -f "$PLAN_FILE" ]]; then
    METADATA_ERRORS+="  - Plan file not found: $PLAN_FILE
"
fi

if [[ -z "$APPROVED_PLAN_HASH" ]]; then
    METADATA_ERRORS+="  - Missing plan_hash marker.
"
elif [[ -n "$PLAN_FILE" && -f "$PLAN_FILE" ]]; then
    CURRENT_PLAN_HASH=$(plan_file_hash "$PLAN_FILE")
    if [[ "$CURRENT_PLAN_HASH" != "$APPROVED_PLAN_HASH" ]]; then
        METADATA_ERRORS+="  - Plan changed since approval (hash mismatch).
"
    fi
fi

if [[ -z "$SCOPE_CONTENT" ]]; then
    METADATA_ERRORS+="  - Missing or empty scope marker.
"
fi

if [[ -z "$OBJECTIVE_VERIFICATION_REQUIRED" ]]; then
    METADATA_ERRORS+="  - Missing objective_verification_required marker.
"
elif [[ "$OBJECTIVE_VERIFICATION_REQUIRED" == "1" && -z "$OBJECTIVE_VERIFICATION" ]]; then
    METADATA_ERRORS+="  - Missing objective_verification marker for a code-change plan.
"
fi

if [[ -n "$METADATA_ERRORS" ]]; then
    deny_tool "BLOCKED: Approval metadata is stale or incomplete.

Detected issues:
${METADATA_ERRORS}
NEXT ACTION: Tell the user to type /approve to rebuild approval metadata. Do NOT call ExitPlanMode."
fi

# ── Scope enforcement ──
IN_SCOPE=false
while IFS= read -r SCOPE_PATH; do
    [[ -z "$SCOPE_PATH" ]] && continue
    [[ "$FILE_PATH" == "$SCOPE_PATH" ]] && IN_SCOPE=true && break
done <<< "$SCOPE_CONTENT"

if [[ "$IN_SCOPE" == "false" ]]; then
    deny_tool "BLOCKED: File not in approved scope.

File: $FILE_PATH

Approved scope:
$(echo "$SCOPE_CONTENT" | sed 's/^/  - /')

NEXT ACTION (3 steps in order):
1. Edit your plan file: add '- ${FILE_PATH}' to ## Scope (exact absolute path, no annotations, no '(new)', no backticks, no comments).
2. Call ExitPlanMode to re-approve.
3. Retry this edit.
Do NOT retry this edit before completing steps 1-2. PROHIBITED in scope entries: backticks, (new), relative paths, glob patterns."
fi

# ── TDD red-green gate ──
# Test files are always allowed. Production files require tests_failed marker.
# Exempt: markdown, plan files, SEP files, memory files (already handled above).
IS_TEST_FILE=false
if [[ "$FILE_PATH" =~ (^|/)test_[^/]*\.(py|sh)$ ]] || \
   [[ "$FILE_PATH" =~ (^|/)[^/]*_test\.(py|go)$ ]] || \
   [[ "$FILE_PATH" =~ (^|/)[^/]*\.(test|spec)\.(ts|js|tsx|jsx)$ ]] || \
   [[ "$FILE_PATH" =~ (^|/)(tests|test|__tests__|spec)/ ]]; then
    IS_TEST_FILE=true
fi

IS_DOC_FILE=false
if [[ "$FILE_PATH" =~ \.(md|mdx|txt|rst)$ ]]; then
    IS_DOC_FILE=true
fi

if [[ "$IS_TEST_FILE" == "false" && "$IS_DOC_FILE" == "false" ]]; then
    if ! state_exists tests_failed; then
        deny_tool "TDD ENFORCEMENT: Tests must fail first.

NEXT ACTION (3 steps in order):
1. Write tests to a test file (patterns: test_*.py, *_test.go, *.test.ts, *.spec.ts, or any file under tests/test/__tests__/spec/ directories).
2. Run them with a recognized test runner (pytest, npm test, go test, cargo test, bun test, etc.).
3. They must EXIT NON-ZERO (fail). Only a non-zero exit unlocks production code editing."
    fi
    if ! state_exists tests_reviewed; then
        deny_tool "TEST REVIEW GATE: Present tests to user for review.

Tests have been written and they fail (red phase complete). Before editing
production code, the user must review the test approach.

WHAT TO DO NOW:
1. Show the user the test file(s) you wrote and explain what each test verifies
2. Ask them to review and choose:
   /approve-tests — tests look good, proceed to implementation
   /skip-tests — skip testing for this task entirely

Do NOT attempt to edit production code until the user responds."
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
Edit #${EDIT_COUNT}. ONLY make changes described in the approved plan.
After ALL edits are done (not after each edit): run the approved ## Objective Verification command, then record it with ~/.claude/scripts/record_validation.sh --command \"<approved verification command>\", then run ~/.claude/scripts/clear_approval.sh.
If the objective cannot be verified, report objective unverified and stop. Do NOT tell the user to /accept unless objective verification has been recorded. Do NOT make additional edits after running clear_approval.sh.
"

if [[ -n "$CONTEXT" ]]; then
    allow_with_context "$CONTEXT"
fi
