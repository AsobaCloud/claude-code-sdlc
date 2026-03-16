#!/bin/bash
# test_approve_plan.sh — regression tests for approve_plan.sh (PostToolUse on ExitPlanMode)
# Verifies that the PostToolUse hook never destroys the approval bundle.
# Implements SEP-008.
# Usage: bash ~/.claude/scripts/tests/test_approve_plan.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASSED=0
FAILED=0
TOTAL=0
FAILURES=""
ORIGINAL_HOME="${HOME}"

source "${SCRIPTS_DIR}/common.sh"

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ── Test harness ──

setup() {
    TEST_TMPDIR=$(mktemp -d)
    export HOME="${TEST_TMPDIR}/home"
    WORKFLOW_DB="${HOME}/.claude/workflow.db"
    _DB_INITIALIZED=""
    export CONV_ID="test-session-001"
    SESSION_ID=""
    CONVERSATION_TOKEN=""
    mkdir -p "$HOME/.claude/plans" "$HOME/.claude"
    ensure_db
    db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('$(sql_escape "$CONV_ID")', '$(pwd)');"
    db_exec "INSERT OR IGNORE INTO sessions (session_id, conversation_id) VALUES ('$(sql_escape "$CONV_ID")', '$(sql_escape "$CONV_ID")');"
    PROJECT_HASH="test"
    CONVERSATION_TOKEN="$CONV_ID"
    PERSIST_DIR="${HOME}/.claude/state/${PROJECT_HASH}/${CONV_ID}"
    mkdir -p "$PERSIST_DIR"
    mkdir -p "$(conversation_plan_dir)"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
    _DB_INITIALIZED=""
    unset CONV_ID 2>/dev/null || true
    SESSION_ID=""
    CONVERSATION_TOKEN=""
    export HOME="${ORIGINAL_HOME}"
    WORKFLOW_DB="${HOME}/.claude/workflow.db"
}

run_hook() {
    local script="$1"
    local json="$2"
    HOOK_OUTPUT=""
    HOOK_EXIT=0
    HOOK_OUTPUT=$(echo "$json" | bash "$script" 2>/dev/null) || HOOK_EXIT=$?
}

assert_state_exists() {
    local key="$1" label="$2"
    TOTAL=$((TOTAL + 1))
    if state_exists "$key"; then
        PASSED=$((PASSED + 1))
        printf "${GREEN}  PASS${NC}: %s\n" "$label"
    else
        FAILED=$((FAILED + 1))
        FAILURES="${FAILURES}\n  FAIL: ${label} (state '$key' does not exist)"
        printf "${RED}  FAIL${NC}: %s (state '%s' does not exist)\n" "$label" "$key"
    fi
}

assert_state_not_exists() {
    local key="$1" label="$2"
    TOTAL=$((TOTAL + 1))
    if ! state_exists "$key"; then
        PASSED=$((PASSED + 1))
        printf "${GREEN}  PASS${NC}: %s\n" "$label"
    else
        FAILED=$((FAILED + 1))
        FAILURES="${FAILURES}\n  FAIL: ${label} (state '$key' unexpectedly exists)"
        printf "${RED}  FAIL${NC}: %s (state '%s' unexpectedly exists)\n" "$label" "$key"
    fi
}

create_test_plan() {
    local plan_file="$HOME/.claude/plans/test-plan.md"
    cat > "$plan_file" <<'PLAN'
# Test Plan

## Objective

This is a test plan objective with more than ten words for validation purposes.

## Scope

- /Users/shingi/.claude/scripts/approve_plan.sh
- /Users/shingi/.claude/scripts/tests/test_approve_plan.sh

## Success Criteria

The test plan succeeds when all assertions pass and no state is destroyed unexpectedly.

## Justification

Testing the approve_plan.sh PostToolUse hook per SEP-008.

## Validation

Sources consulted: approve_plan.sh, common.sh, ARCHITECTURE.md.
Evidence: the destructive state_remove approved call violates architecture contract.
Verified: approve_plan.sh line 24 removes approved unconditionally on fallthrough.
Known gaps: none for this test.

## Objective Verification

Run test_approve_plan.sh and confirm all scenarios pass.
PLAN
    echo "$plan_file"
}

HOOK_JSON='{"session_id":"test-session-001","tool_name":"ExitPlanMode"}'

# ══════════════════════════════════════════════════════════════════════
# Scenario 1: Normal flow — PreToolUse writes bundle, PostToolUse preserves it
# ══════════════════════════════════════════════════════════════════════
printf "\n${YELLOW}Scenario 1: Normal flow — approval preserved after PostToolUse${NC}\n"
setup

PLAN_FILE=$(create_test_plan)
state_write planning "1"
state_write planning_started_at "$(date +%s)"

write_approval_bundle "$PLAN_FILE"

assert_state_exists "approved" "Pre-check: approved exists before PostToolUse"

run_hook "${SCRIPTS_DIR}/approve_plan.sh" "$HOOK_JSON"

assert_state_exists "approved" "approved preserved after PostToolUse (normal flow)"
assert_state_exists "plan_hash" "plan_hash preserved after PostToolUse"
assert_state_exists "scope" "scope preserved after PostToolUse"
assert_state_not_exists "planning" "planning cleared by PostToolUse"
assert_state_not_exists "planning_started_at" "planning_started_at cleared by PostToolUse"

teardown

# ══════════════════════════════════════════════════════════════════════
# Scenario 2: Degraded flow — approval_bundle_is_complete fails, approved NOT removed
# ══════════════════════════════════════════════════════════════════════
printf "\n${YELLOW}Scenario 2: Degraded flow — bundle check fails but approved NOT removed${NC}\n"
setup

PLAN_FILE=$(create_test_plan)
state_write planning "1"
state_write planning_started_at "$(date +%s)"

write_approval_bundle "$PLAN_FILE"

# Corrupt the hash so approval_bundle_is_complete will fail
state_write plan_hash "corrupted_hash_value"

assert_state_exists "approved" "Pre-check: approved exists before PostToolUse"

run_hook "${SCRIPTS_DIR}/approve_plan.sh" "$HOOK_JSON"

# THE KEY ASSERTION: approved must NOT be removed even when bundle check fails
assert_state_exists "approved" "approved NOT removed despite bundle check failure (the fix)"
assert_state_exists "plan_file" "plan_file preserved despite bundle check failure"
assert_state_exists "scope" "scope preserved despite bundle check failure"

teardown

# ══════════════════════════════════════════════════════════════════════
# Scenario 3: Fallback repair — missing state marker repaired by PostToolUse
# ══════════════════════════════════════════════════════════════════════
printf "\n${YELLOW}Scenario 3: Fallback repair — PostToolUse repairs incomplete bundle${NC}\n"
setup

PLAN_FILE=$(create_test_plan)
state_write planning "1"
state_write planning_started_at "$(date +%s)"

write_approval_bundle "$PLAN_FILE"

# Remove one marker to make bundle incomplete
state_remove scope

assert_state_exists "approved" "Pre-check: approved exists"
assert_state_not_exists "scope" "Pre-check: scope removed to simulate partial state"

run_hook "${SCRIPTS_DIR}/approve_plan.sh" "$HOOK_JSON"

assert_state_exists "approved" "approved preserved after fallback repair"
assert_state_exists "scope" "scope repaired by PostToolUse fallback"
assert_state_exists "plan_hash" "plan_hash exists after repair"

teardown

# ══════════════════════════════════════════════════════════════════════
# Scenario 4: Static check — no state_remove approved in approve_plan.sh
# ══════════════════════════════════════════════════════════════════════
printf "\n${YELLOW}Scenario 4: Static check — no state_remove approved in approve_plan.sh${NC}\n"
TOTAL=$((TOTAL + 1))
if grep -q 'state_remove approved' "${SCRIPTS_DIR}/approve_plan.sh"; then
    FAILED=$((FAILED + 1))
    FAILURES="${FAILURES}\n  FAIL: approve_plan.sh still contains state_remove approved"
    printf "${RED}  FAIL${NC}: approve_plan.sh still contains state_remove approved\n"
else
    PASSED=$((PASSED + 1))
    printf "${GREEN}  PASS${NC}: approve_plan.sh does not contain state_remove approved\n"
fi

# ══════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════
printf "\n${YELLOW}═══ Results ═══${NC}\n"
printf "Total: %d  Passed: %d  Failed: %d\n" "$TOTAL" "$PASSED" "$FAILED"
if [[ $FAILED -gt 0 ]]; then
    printf "${RED}Failures:${NC}%b\n" "$FAILURES"
    exit 1
fi
printf "${GREEN}All tests passed.${NC}\n"
exit 0
