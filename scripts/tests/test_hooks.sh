#!/bin/bash
# test_hooks.sh — end-to-end tests for Claude hook scripts
# Runs each hook against isolated temp directories using env-var overrides.
# Usage: bash ~/.claude/scripts/tests/test_hooks.sh

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
    export CLAUDE_TEST_PERSIST_DIR="${TEST_TMPDIR}/persist"
    export CLAUDE_TEST_STATE_DIR="${CLAUDE_TEST_PERSIST_DIR}"
    export CLAUDE_TEST_HOOKS_DIR="${TEST_TMPDIR}/hooks"
    mkdir -p "$HOME/.claude/plans" "$HOME/.claude/shared-memory" "$CLAUDE_TEST_STATE_DIR" "$CLAUDE_TEST_PERSIST_DIR" "$CLAUDE_TEST_HOOKS_DIR"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
    unset CLAUDE_TEST_STATE_DIR CLAUDE_TEST_PERSIST_DIR CLAUDE_TEST_HOOKS_DIR
    export HOME="${ORIGINAL_HOME}"
}

# Run a hook script, piping JSON on stdin. Sets HOOK_OUTPUT and HOOK_EXIT.
run_hook() {
    local script="$1"
    local json="$2"
    HOOK_OUTPUT=""
    HOOK_EXIT=0
    HOOK_OUTPUT=$(echo "$json" | bash "$script" 2>/dev/null) || HOOK_EXIT=$?
}

run_script() {
    HOOK_OUTPUT=""
    HOOK_EXIT=0
    HOOK_OUTPUT=$("$@" 2>&1) || HOOK_EXIT=$?
}

# ── Assertions ──

assert_file_exists() {
    local path="$1"
    local label="${2:-$path}"
    if [[ ! -f "$path" ]]; then
        fail "Expected file to exist: $label"
        return 1
    fi
    return 0
}

assert_file_missing() {
    local path="$1"
    local label="${2:-$path}"
    if [[ -f "$path" ]]; then
        fail "Expected file NOT to exist: $label"
        return 1
    fi
    return 0
}

assert_file_contains() {
    local path="$1"
    local pattern="$2"
    local label="${3:-$path contains '$pattern'}"
    if ! grep -q "$pattern" "$path" 2>/dev/null; then
        fail "File $path does not contain pattern: $pattern"
        return 1
    fi
    return 0
}

assert_output_contains() {
    local pattern="$1"
    local label="${2:-output contains '$pattern'}"
    if ! echo "$HOOK_OUTPUT" | grep -q "$pattern" 2>/dev/null; then
        fail "Output does not contain: $pattern (got: ${HOOK_OUTPUT:0:200})"
        return 1
    fi
    return 0
}

assert_output_not_contains() {
    local pattern="$1"
    if echo "$HOOK_OUTPUT" | grep -q "$pattern" 2>/dev/null; then
        fail "Output should NOT contain: $pattern"
        return 1
    fi
    return 0
}

assert_exit_code() {
    local expected="$1"
    if [[ "$HOOK_EXIT" -ne "$expected" ]]; then
        fail "Expected exit code $expected, got $HOOK_EXIT"
        return 1
    fi
    return 0
}

assert_json_field() {
    local field="$1"
    local expected="$2"
    local actual
    actual=$(echo "$HOOK_OUTPUT" | jq -r "$field" 2>/dev/null)
    if [[ "$actual" != "$expected" ]]; then
        fail "JSON field $field: expected '$expected', got '$actual'"
        return 1
    fi
    return 0
}

# ── Test result tracking ──

current_test=""

begin_test() {
    current_test="$1"
    TOTAL=$(( TOTAL + 1 ))
}

pass() {
    PASSED=$(( PASSED + 1 ))
    printf "${GREEN}  PASS${NC} %s\n" "$current_test"
}

fail() {
    FAILED=$(( FAILED + 1 ))
    local reason="${1:-}"
    printf "${RED}  FAIL${NC} %s: %s\n" "$current_test" "$reason"
    FAILURES+="  - $current_test: $reason\n"
}

# ── Minimal JSON templates ──

json_pretooluse() {
    local tool="$1"
    local file_path="${2:-}"
    local pattern="${3:-}"
    local search_path="${4:-}"
    local input="{}"
    if [[ -n "$file_path" ]]; then
        input=$(jq -n --arg fp "$file_path" '{"file_path":$fp}')
    elif [[ -n "$pattern" ]]; then
        input=$(jq -n --arg p "$pattern" --arg sp "$search_path" '{"pattern":$p,"path":$sp}')
    fi
    jq -n --arg tool "$tool" --argjson input "$input" \
        '{"session_id":"test-session-001","tool_name":$tool,"tool_input":$input}'
}

json_posttooluse() {
    local tool="$1"
    jq -n --arg tool "$tool" \
        '{"session_id":"test-session-001","tool_name":$tool,"tool_input":{}}'
}

json_bash_pretooluse() {
    local command="$1"
    jq -n --arg cmd "$command" \
        '{"session_id":"test-session-001","tool_name":"Bash","tool_input":{"command":$cmd}}'
}

write_plan() {
    local plan_file="$1"
    local objective="$2"
    local scope_block="$3"
    local criteria="$4"
    local justification="$5"
    local validation="$6"
    local objective_verification="${7:-Review the resulting behavior in the real workspace and confirm the approved objective is met.}"

    mkdir -p "$(dirname "$plan_file")"
    cat > "$plan_file" <<EOF
## Objective
$objective

## Scope
$scope_block

## Success Criteria
$criteria

## Justification
$justification

## Validation
$validation
EOF

    cat >> "$plan_file" <<EOF

## Objective Verification
$objective_verification
EOF
}

seed_approval_bundle_from_plan() {
    local plan_file="$1"
    PERSIST_DIR="${CLAUDE_TEST_PERSIST_DIR}"
    PROJECT_HASH="test-project"
    write_approval_bundle "$plan_file" >/dev/null
}

mark_tdd_ready() {
    echo "2026-03-10T00:00:00Z pytest" > "${CLAUDE_TEST_PERSIST_DIR}/tests_failed"
    echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/tests_reviewed"
}

# ══════════════════════════════════════════════════════════════════
# GROUP 1: init_hook / env-var overrides
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 1: init_hook / env-var overrides ──${NC}\n"

begin_test "1.3 Missing session_id + env var still runs"
setup
local_json='{"tool_name":"EnterPlanMode","tool_input":{}}'
run_hook "${SCRIPTS_DIR}/clear_plan_on_new_task.sh" "$local_json"
assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/planning" "planning marker without session_id" && pass
teardown

begin_test "1.4 Missing session_id + no env var → exit 0"
setup
PERSIST_PATH="${CLAUDE_TEST_PERSIST_DIR}"
unset CLAUDE_TEST_STATE_DIR CLAUDE_TEST_PERSIST_DIR CLAUDE_TEST_HOOKS_DIR
run_hook "${SCRIPTS_DIR}/clear_plan_on_new_task.sh" '{"tool_name":"EnterPlanMode","tool_input":{}}'
assert_exit_code 0 \
    && assert_file_missing "${PERSIST_PATH}/planning" "planning marker should not be created" \
    && pass
teardown

# ══════════════════════════════════════════════════════════════════
# GROUP 2: require_plan_approval.sh
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 2: require_plan_approval.sh ──${NC}\n"

REQUIRE="${SCRIPTS_DIR}/require_plan_approval.sh"

begin_test "2.1 No approved file → deny"
setup
run_hook "$REQUIRE" "$(json_pretooluse Edit /some/file.md)"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'deny'; then
    pass
fi
teardown

begin_test "2.2 Complete approval bundle → allow"
setup
PLAN_FILE="${HOME}/.claude/plans/approved-doc-plan.md"
write_plan \
    "$PLAN_FILE" \
    "Update the current hook documentation within a single approved markdown file." \
    "- /some/file.md" \
    "The scoped documentation edit is allowed once approval metadata exists." \
    "Per /Users/shingi/.claude/CLAUDE.md, this keeps the change inside the approved file and follows the existing current documentation workflow." \
    "I read the current scripts and documentation and verified this is a documentation-only scoped edit for the current codebase."
seed_approval_bundle_from_plan "$PLAN_FILE"
run_hook "$REQUIRE" "$(json_pretooluse Edit /some/file.md)"
assert_json_field '.hookSpecificOutput.permissionDecision' 'allow' \
    && pass
teardown

begin_test "2.3 Plan file paths always allowed"
setup
run_hook "$REQUIRE" "$(json_pretooluse Write /home/user/.claude/plans/plan.md)"
if assert_exit_code 0; then
    assert_output_not_contains '"deny"' && pass
fi
teardown

begin_test "2.4 Scope enforcement: in-scope → allow"
setup
PLAN_FILE="${HOME}/.claude/plans/scope-doc-plan.md"
write_plan \
    "$PLAN_FILE" \
    "Update the current hook guide in one approved markdown file for scope testing." \
    "- /project/src/main.md" \
    "The in-scope markdown edit passes the approval gate." \
    "Per /Users/shingi/.claude/CLAUDE.md, this test uses the existing scope rules with a documentation-only file." \
    "I read the current gate scripts and verified this markdown path should bypass the TDD production-file checks."
seed_approval_bundle_from_plan "$PLAN_FILE"
run_hook "$REQUIRE" "$(json_pretooluse Edit /project/src/main.md)"
assert_json_field '.hookSpecificOutput.permissionDecision' 'allow' && pass
teardown

begin_test "2.5 Scope enforcement: out-of-scope → deny"
setup
PLAN_FILE="${HOME}/.claude/plans/scope-deny-plan.md"
write_plan \
    "$PLAN_FILE" \
    "Update one approved documentation file and reject edits outside the scope." \
    "- /project/src/main.md" \
    "Only the scoped markdown file can be edited." \
    "Per /Users/shingi/.claude/CLAUDE.md, scope is fail-closed and should block out-of-scope edits." \
    "I read the current scope gate and verified the exact file path must match the approved scope."
seed_approval_bundle_from_plan "$PLAN_FILE"
run_hook "$REQUIRE" "$(json_pretooluse Edit /project/tests/bad.md)"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'deny'; then
    pass
fi
teardown

begin_test "2.6 Context injection on first edit"
setup
PLAN_FILE="${HOME}/.claude/plans/context-plan.md"
write_plan \
    "$PLAN_FILE" \
    "Build the widget guide in one approved markdown file with explicit success criteria." \
    "- /project/src/widget.md" \
    "The widget guide documents the current hook behavior correctly." \
    "Per /Users/shingi/.claude/CLAUDE.md, the context should restate the approved objective and criteria during editing." \
    "I read the current approval gate and verified the allow response injects objective, scope, criteria, and the edit counter."
seed_approval_bundle_from_plan "$PLAN_FILE"
run_hook "$REQUIRE" "$(json_pretooluse Edit /project/src/widget.md)"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'allow'; then
    assert_output_contains "OBJECTIVE" \
        && assert_output_contains "SUCCESS CRITERIA" \
        && assert_output_contains "Edit #1" \
        && pass
fi
teardown

# ══════════════════════════════════════════════════════════════════
# GROUP 3: approve_plan.sh (PostToolUse on ExitPlanMode)
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 3: approve_plan.sh ──${NC}\n"

APPROVE="${SCRIPTS_DIR}/approve_plan.sh"

begin_test "3.1 approve_plan backfills approval bundle from plan file"
setup
PLAN_FILE="${HOME}/.claude/plans/approve-plan-backfill.md"
write_plan \
    "$PLAN_FILE" \
    "Backfill approval metadata from the newest plan file for the current project." \
    "- /tmp/approved-doc.md" \
    "The approval bundle is rebuilt from plan metadata." \
    "Per /Users/shingi/.claude/README.md, approve_plan.sh is the current PostToolUse fallback for state consistency." \
    "I read the current approval scripts and verified this path should rebuild the persistent approval bundle."
run_hook "$APPROVE" "$(json_posttooluse ExitPlanMode)"
assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/approved" "approved marker" \
    && assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/plan_hash" "plan_hash marker" \
    && assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/plan_file" "plan_file marker" \
    && pass
teardown

begin_test "3.2 approve_plan extracts objective, scope, and criteria"
setup
PLAN_FILE="${HOME}/.claude/plans/approve-plan-sections.md"
write_plan \
    "$PLAN_FILE" \
    "Build a test harness for validating hook behavior end to end in documentation." \
    "- /tmp/test_hooks.md" \
    "The test harness documentation is extracted into approval state files." \
    "Per /Users/shingi/.claude/CLAUDE.md, approval metadata should reflect the current plan sections exactly." \
    "I read the current extraction helpers and verified objective, scope, and criteria are persisted from the plan."
run_hook "$APPROVE" "$(json_posttooluse ExitPlanMode)"
assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/objective" \
    && assert_file_contains "${CLAUDE_TEST_PERSIST_DIR}/objective" "test harness" \
    && assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/scope" \
    && assert_file_contains "${CLAUDE_TEST_PERSIST_DIR}/scope" "/tmp/test_hooks.md" \
    && assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/criteria" \
    && pass
teardown

begin_test "3.3 approve_plan clears planning markers"
setup
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/planning"
echo "$(date +%s)" > "${CLAUDE_TEST_PERSIST_DIR}/planning_started_at"
PLAN_FILE="${HOME}/.claude/plans/approve-plan-cleanup.md"
write_plan \
    "$PLAN_FILE" \
    "Clear planning markers after approval metadata is rebuilt from the current plan." \
    "- /tmp/cleanup-doc.md" \
    "Planning markers are removed when approval succeeds." \
    "Per /Users/shingi/.claude/README.md, the approval fallback should leave the project out of planning mode." \
    "I read the current PostToolUse approval script and verified it removes planning and planning_started_at."
run_hook "$APPROVE" "$(json_posttooluse ExitPlanMode)"
assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/planning" "planning marker cleaned" \
    && assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/planning_started_at" "planning_started_at cleaned" \
    && pass
teardown

# ══════════════════════════════════════════════════════════════════
# GROUP 4: clear_plan_on_new_task.sh (PostToolUse on EnterPlanMode)
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 4: clear_plan_on_new_task.sh ──${NC}\n"

CLEAR_TASK="${SCRIPTS_DIR}/clear_plan_on_new_task.sh"

begin_test "4.1 clear_plan_on_new_task clears approval and validation markers"
setup
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/approved"
echo "obj" > "${CLAUDE_TEST_PERSIST_DIR}/objective"
echo "sc" > "${CLAUDE_TEST_PERSIST_DIR}/scope"
echo "cr" > "${CLAUDE_TEST_PERSIST_DIR}/criteria"
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/objective_verification_required"
echo "verify" > "${CLAUDE_TEST_PERSIST_DIR}/objective_verification"
echo "ts" > "${CLAUDE_TEST_PERSIST_DIR}/objective_verified"
echo "hash" > "${CLAUDE_TEST_PERSIST_DIR}/objective_verified_hash"
echo "pending" > "${CLAUDE_TEST_PERSIST_DIR}/accept_bypass_pending"
echo "user" > "${CLAUDE_TEST_PERSIST_DIR}/user_bypass"
echo "dirty" > "${CLAUDE_TEST_PERSIST_DIR}/dirty"
echo "unit" > "${CLAUDE_TEST_PERSIST_DIR}/validated_unit"
echo "e2e" > "${CLAUDE_TEST_PERSIST_DIR}/validated_e2e"
echo "red" > "${CLAUDE_TEST_PERSIST_DIR}/tests_failed"
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/tests_reviewed"
run_hook "$CLEAR_TASK" "$(json_posttooluse EnterPlanMode)"
assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/approved" \
    && assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/objective_verification_required" \
    && assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/objective_verified" \
    && assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/accept_bypass_pending" \
    && assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/user_bypass" \
    && assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/dirty" \
    && assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/validated_unit" \
    && assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/tests_failed" \
    && pass
teardown

begin_test "4.2 clear_plan_on_new_task creates planning markers"
setup
run_hook "$CLEAR_TASK" "$(json_posttooluse EnterPlanMode)"
assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/planning" "planning marker" \
    && assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/planning_started_at" "planning_started_at marker" \
    && pass
teardown

begin_test "4.3 clear_plan_on_new_task clears validation_log and approval_token"
setup
echo "log entry" > "${CLAUDE_TEST_PERSIST_DIR}/validation_log"
echo "token-123" > "${CLAUDE_TEST_PERSIST_DIR}/approval_token"
run_hook "$CLEAR_TASK" "$(json_posttooluse EnterPlanMode)"
assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/validation_log" "validation_log cleaned" \
    && assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/approval_token" "approval_token cleaned" \
    && pass
teardown

# ══════════════════════════════════════════════════════════════════
# GROUP 5: track_dirty.sh
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 5: track_dirty.sh ──${NC}\n"

TRACK_DIRTY="${SCRIPTS_DIR}/track_dirty.sh"

begin_test "5.1 track_dirty sets dirty marker on normal edit"
setup
run_hook "$TRACK_DIRTY" "$(json_pretooluse Edit /some/file.py)"
assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/dirty" "dirty marker" \
    && assert_file_contains "${CLAUDE_TEST_PERSIST_DIR}/dirty" "/some/file.py" \
    && pass
teardown

begin_test "5.2 track_dirty ignores plan files"
setup
run_hook "$TRACK_DIRTY" "$(json_pretooluse Edit ${HOME}/.claude/plans/test-plan.md)"
assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/dirty" "dirty should not be set for plan edits" \
    && pass
teardown

begin_test "5.3 track_dirty ignores memory files"
setup
run_hook "$TRACK_DIRTY" "$(json_pretooluse Edit ${HOME}/.claude/projects/demo/memory/MEMORY.md)"
assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/dirty" "dirty should not be set for memory edits" \
    && pass
teardown

# ══════════════════════════════════════════════════════════════════
# GROUP 6: Standalone scripts
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 6: Standalone scripts ──${NC}\n"

begin_test "6.1 restore_approval.sh creates approval bundle"
setup
PLAN_FILE="${HOME}/.claude/plans/_test_restore_approval.md"
write_plan \
    "$PLAN_FILE" \
    "Restore approval from the current plan for a standalone workflow test." \
    "- /tmp/test.txt" \
    "Approval metadata is rebuilt from the current plan." \
    "Per /Users/shingi/.claude/commands/approve.md, /approve routes through restore_approval.sh for current plan approval." \
    "I read the current restore script and verified it rebuilds approval metadata from the newest plan file." \
    "Run echo ok against the real shell and verify the output."
run_script bash "${SCRIPTS_DIR}/restore_approval.sh"
assert_exit_code 0 \
    && assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/approved" "persist/approved" \
    && assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/plan_hash" "plan_hash" \
    && assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/objective_verification" "objective_verification" \
    && pass
teardown

begin_test "6.2 accept_outcome.sh --finalize clears approval"
setup
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/approved"
echo "obj" > "${CLAUDE_TEST_PERSIST_DIR}/objective"
echo "0" > "${CLAUDE_TEST_PERSIST_DIR}/objective_verification_required"
run_script bash "${SCRIPTS_DIR}/accept_outcome.sh" --finalize
assert_exit_code 0 \
    && assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/approved" \
    && assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/objective" \
    && pass
teardown

begin_test "6.3 reject_outcome.sh clears approval"
setup
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/approved"
echo "sc" > "${CLAUDE_TEST_PERSIST_DIR}/scope"
run_script bash "${SCRIPTS_DIR}/reject_outcome.sh"
assert_exit_code 0 \
    && assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/approved" \
    && assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/scope" \
    && pass
teardown

begin_test "6.4 clear_approval.sh clears all state"
setup
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/approved"
echo "crit" > "${CLAUDE_TEST_PERSIST_DIR}/criteria"
echo "0" > "${CLAUDE_TEST_PERSIST_DIR}/objective_verification_required"
run_script bash "${SCRIPTS_DIR}/clear_approval.sh"
assert_exit_code 0 \
    && assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/approved" \
    && assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/criteria" \
    && pass
teardown

# ══════════════════════════════════════════════════════════════════
# GROUP 7: Workflow integration tests (multi-step sequences)
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 7: Workflow integration tests ──${NC}\n"

APPROVE="${SCRIPTS_DIR}/approve_plan.sh"
REQUIRE="${SCRIPTS_DIR}/require_plan_approval.sh"
CLEAR_TASK="${SCRIPTS_DIR}/clear_plan_on_new_task.sh"
VALIDATE="${SCRIPTS_DIR}/validate_plan_quality.sh"

begin_test "7.1 Full workflow: EnterPlanMode → validate → edit allowed"
setup
run_hook "$CLEAR_TASK" "$(json_posttooluse EnterPlanMode)"
PLAN_FILE="${HOME}/.claude/plans/workflow-doc-plan.md"
write_plan \
    "$PLAN_FILE" \
    "Implements SEP-101 by updating the current workflow documentation in one approved markdown file after planning." \
    "- /some/file.md" \
    "The scoped documentation edit is allowed after validate_plan_quality approves the plan." \
    "Per /Users/shingi/.claude/CLAUDE.md, this follows the current planning workflow and stays inside the approved scope." \
    "I read the current hook scripts and existing documentation and verified this plan reflects the current codebase, the current workflow, and the active approval rules."
run_hook "$VALIDATE" "$(json_pretooluse ExitPlanMode)"
run_hook "$REQUIRE" "$(json_pretooluse Edit /some/file.md)"
assert_json_field '.hookSpecificOutput.permissionDecision' 'allow' && pass
teardown

begin_test "7.2 restore_approval enables editing from the current plan"
setup
PLAN_FILE="${HOME}/.claude/plans/restore-flow-plan.md"
write_plan \
    "$PLAN_FILE" \
    "Restore approval for the current documentation change using the user approval flow." \
    "- /restore/file.md" \
    "The restored approval bundle allows the scoped markdown edit." \
    "Per /Users/shingi/.claude/commands/approve.md, the user approval command restores approval from the current plan." \
    "I read the current approval command flow and verified restore_approval.sh rebuilds the bundle without plan mode state."
run_script bash "${SCRIPTS_DIR}/restore_approval.sh"
run_hook "$REQUIRE" "$(json_pretooluse Edit /restore/file.md)"
assert_json_field '.hookSpecificOutput.permissionDecision' 'allow' && pass
teardown

begin_test "7.3 EnterPlanMode clears previous approval and starts a new plan cycle"
setup
PLAN_FILE="${HOME}/.claude/plans/old-approved-plan.md"
write_plan \
    "$PLAN_FILE" \
    "Seed an approved documentation plan and then start a fresh planning cycle." \
    "- /old/file.md" \
    "The old approval bundle is cleared when a new plan cycle begins." \
    "Per /Users/shingi/.claude/SDLC.md, EnterPlanMode clears prior approval before starting a new task." \
    "I read the current new-task hook and verified it removes approval state before writing planning markers."
seed_approval_bundle_from_plan "$PLAN_FILE"
run_hook "$CLEAR_TASK" "$(json_posttooluse EnterPlanMode)"
assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/approved" "approved should be cleared" \
    && assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/planning" "planning should be active" \
    && pass
teardown

begin_test "7.4 Recovery: blocked edit → restore approval → edit works"
setup
PLAN_FILE="${HOME}/.claude/plans/recovery-plan.md"
write_plan \
    "$PLAN_FILE" \
    "Recover from a blocked scoped edit by restoring approval from the current plan." \
    "- /recover/file.md" \
    "Editing works after the user approval flow rebuilds the bundle." \
    "Per /Users/shingi/.claude/commands/approve.md, restore_approval.sh is the user-controlled recovery path for approval state." \
    "I read the current recovery scripts and verified a blocked edit should succeed after restore_approval recreates the bundle."
run_hook "$REQUIRE" "$(json_pretooluse Edit /recover/file.md)"
assert_json_field '.hookSpecificOutput.permissionDecision' 'deny'
run_script bash "${SCRIPTS_DIR}/restore_approval.sh"
run_hook "$REQUIRE" "$(json_pretooluse Edit /recover/file.md)"
assert_json_field '.hookSpecificOutput.permissionDecision' 'allow' && pass
teardown

begin_test "7.5 BLOCKED with existing plan → suggests ExitPlanMode"
setup
TEMP_PLAN="${HOME}/.claude/plans/_test_plan_7_5.md"
echo "test plan" > "$TEMP_PLAN"
run_hook "$REQUIRE" "$(json_pretooluse Edit /some/file.md)"
assert_output_contains "Call ExitPlanMode" \
    && pass
teardown

begin_test "7.6 BLOCKED without plan file → suggests EnterPlanMode"
setup
run_hook "$REQUIRE" "$(json_pretooluse Edit /some/file.md)"
assert_output_contains "EnterPlanMode" && pass
teardown

begin_test "7.7 validate_plan_quality creates approval and objective verification metadata"
setup
run_hook "$CLEAR_TASK" "$(json_posttooluse EnterPlanMode)"
TEMP_PLAN="${HOME}/.claude/plans/_test_plan_7_7.md"
write_plan \
    "$TEMP_PLAN" \
    "Implements SEP-102 by validating the current code-path approval flow and recording real end to end proof." \
    "- /src/app.py" \
    "Plan approval stores the objective verification command for the current code change." \
    "Per /Users/shingi/.claude/CLAUDE.md, code-change plans must define real end to end objective verification." \
    "I read the current validation and approval scripts and verified this code-change plan must persist objective proof instructions, scope metadata, and approval state for the current implementation." \
    "Run python verify_real_system.py against the live service and confirm the objective works."
run_hook "$VALIDATE" "$(json_pretooluse ExitPlanMode)"
assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/approved" "approved created" \
    && assert_file_contains "${CLAUDE_TEST_PERSIST_DIR}/objective_verification_required" "1" \
    && assert_file_contains "${CLAUDE_TEST_PERSIST_DIR}/objective_verification" "python verify_real_system.py" \
    && assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/planning" "planning cleaned up" \
    && assert_output_contains "record objective verification" \
    && pass
teardown

begin_test "7.8 approve_plan is idempotent after validate_plan_quality"
setup
run_hook "$CLEAR_TASK" "$(json_posttooluse EnterPlanMode)"
TEMP_PLAN="${HOME}/.claude/plans/_test_plan_7_8.md"
write_plan \
    "$TEMP_PLAN" \
    "Implements SEP-103 by approving the current documentation plan and keeping the bundle stable across both ExitPlanMode hooks." \
    "- /tmp/idempotent.md" \
    "Both ExitPlanMode hooks leave a coherent approval bundle in place." \
    "Per /Users/shingi/.claude/README.md, validate_plan_quality approves first and approve_plan backfills only if needed." \
    "I read the current ExitPlanMode scripts and verified approve_plan should preserve an already-complete bundle, matching the existing current approval flow and metadata rules."
run_hook "$VALIDATE" "$(json_pretooluse ExitPlanMode)"
FIRST_HASH="$(cat "${CLAUDE_TEST_PERSIST_DIR}/plan_hash" 2>/dev/null || true)"
run_hook "$APPROVE" "$(json_posttooluse ExitPlanMode)"
SECOND_HASH="$(cat "${CLAUDE_TEST_PERSIST_DIR}/plan_hash" 2>/dev/null || true)"
if [[ -n "$FIRST_HASH" ]] && [[ "$FIRST_HASH" == "$SECOND_HASH" ]] && [[ -f "${CLAUDE_TEST_PERSIST_DIR}/approved" ]]; then
    pass
else
    fail "plan_hash changed or approved marker missing after approve_plan"
fi
teardown

# ══════════════════════════════════════════════════════════════════
# GROUP 8: SEP commit check (sep_commit_check.sh)
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 8: sep_commit_check.sh ──${NC}\n"

SEP_CHECK="${SCRIPTS_DIR}/sep_commit_check.sh"

# 8.1 git commit without SEP reference → deny
begin_test "8.1 git commit without SEP ref → deny"
setup
run_hook "$SEP_CHECK" "$(json_bash_pretooluse "git commit -m 'fix a bug'")"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'deny'; then
    pass
fi
teardown

# 8.2 git commit with SEP reference → allow
begin_test "8.2 git commit with SEP-001 in message → allow"
setup
run_hook "$SEP_CHECK" "$(json_bash_pretooluse "git commit -m 'SEP-001: fix a bug'")"
assert_exit_code 0 && assert_output_not_contains '"deny"' && pass
teardown

# 8.3 git commit on exempt project → allow
begin_test "8.3 git commit on .sep-exempt project → allow"
setup
# Create .sep-exempt in current directory
touch "${CLAUDE_PROJECT_DIR:-.}/.sep-exempt" 2>/dev/null || touch ".sep-exempt"
run_hook "$SEP_CHECK" "$(json_bash_pretooluse "git commit -m 'no sep needed'")"
assert_exit_code 0 && assert_output_not_contains '"deny"' && pass
rm -f "${CLAUDE_PROJECT_DIR:-.}/.sep-exempt" 2>/dev/null; rm -f ".sep-exempt"
teardown

# 8.4 Non-git-commit Bash command → allow
begin_test "8.4 Non-git-commit command → allow"
setup
run_hook "$SEP_CHECK" "$(json_bash_pretooluse "ls -la /tmp")"
assert_exit_code 0 && assert_output_not_contains '"deny"' && pass
teardown

# ══════════════════════════════════════════════════════════════════
# GROUP 9: SEP validation in plan quality
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 9: SEP plan validation ──${NC}\n"

VALIDATE="${SCRIPTS_DIR}/validate_plan_quality.sh"

# 9.1 Plan without SEP reference on non-exempt project → deny
begin_test "9.1 Plan without SEP ref → deny"
setup
echo "1" > "${CLAUDE_TEST_STATE_DIR}/planning"
echo "5" > "${CLAUDE_TEST_STATE_DIR}/explore_count"
echo "READ: /some/readme.md" > "${CLAUDE_TEST_STATE_DIR}/exploration_log"
echo "READ: /some/main.sh" >> "${CLAUDE_TEST_STATE_DIR}/exploration_log"
echo "SEARCH: hooks | /some/dir" >> "${CLAUDE_TEST_STATE_DIR}/exploration_log"
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/planning"
TEMP_PLAN="${HOME}/.claude/plans/_test_plan_91.md"
cat > "$TEMP_PLAN" <<'PLAN'
# No SEP Reference Plan

## Objective
Fix the readme file to have correct documentation for the existing project.

## Scope
- ~/project/readme.md
- ~/project/main.sh

## Success Criteria
The readme accurately describes the project and all sections are complete.

## Justification
Per CLAUDE.md documentation requirements. This follows existing patterns in scripts/.
PLAN
# Remove any .sep-exempt to ensure check runs
rm -f "${CLAUDE_PROJECT_DIR:-.}/.sep-exempt" 2>/dev/null
run_hook "$VALIDATE" "$(json_pretooluse ExitPlanMode)"
rm -f "$TEMP_PLAN"
assert_output_contains "NO SEP REFERENCE" && pass
teardown

# 9.2 Plan with SEP reference → pass (no SEP error)
begin_test "9.2 Plan with SEP-005 ref → no SEP error"
setup
echo "1" > "${CLAUDE_TEST_STATE_DIR}/planning"
echo "5" > "${CLAUDE_TEST_STATE_DIR}/explore_count"
echo "READ: /some/validate_plan_quality.sh" > "${CLAUDE_TEST_STATE_DIR}/exploration_log"
echo "READ: /some/approve_plan.sh" >> "${CLAUDE_TEST_STATE_DIR}/exploration_log"
echo "SEARCH: hooks | /some/scripts" >> "${CLAUDE_TEST_STATE_DIR}/exploration_log"
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/planning"
TEMP_PLAN="${HOME}/.claude/plans/_test_plan_92.md"
cat > "$TEMP_PLAN" <<'PLAN'
# Fix Plan SEP-005

## Objective
Fix the approval workflow per SEP-005 to validate plan quality in the existing codebase.

## Scope
- ~/.claude/scripts/validate_plan_quality.sh
- ~/.claude/scripts/approve_plan.sh

## Success Criteria
After ExitPlanMode, approved marker exists and editing is unlocked without manual intervention.

## Justification
Per CLAUDE.md workflow documentation. This follows existing patterns in scripts/.
PLAN
run_hook "$VALIDATE" "$(json_pretooluse ExitPlanMode)"
rm -f "$TEMP_PLAN"
assert_output_not_contains "NO SEP REFERENCE" && pass
teardown

# 9.3 Plan on exempt project without SEP → pass (no SEP error)
begin_test "9.3 Exempt project: no SEP needed → pass"
setup
echo "1" > "${CLAUDE_TEST_STATE_DIR}/planning"
echo "5" > "${CLAUDE_TEST_STATE_DIR}/explore_count"
echo "READ: /some/readme.md" > "${CLAUDE_TEST_STATE_DIR}/exploration_log"
echo "READ: /some/main.sh" >> "${CLAUDE_TEST_STATE_DIR}/exploration_log"
echo "SEARCH: hooks | /some/dir" >> "${CLAUDE_TEST_STATE_DIR}/exploration_log"
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/planning"
TEMP_PLAN="${HOME}/.claude/plans/_test_plan_93.md"
cat > "$TEMP_PLAN" <<'PLAN'
# No SEP Plan on Exempt Project

## Objective
Fix the readme file to have correct documentation for the existing project.

## Scope
- ~/project/readme.md
- ~/project/main.sh

## Success Criteria
The readme accurately describes the project and all sections are complete.

## Justification
Per CLAUDE.md documentation requirements. This follows existing patterns in scripts/.
PLAN
# Create .sep-exempt to mark as exempt
touch "${CLAUDE_PROJECT_DIR:-.}/.sep-exempt" 2>/dev/null || touch ".sep-exempt"
run_hook "$VALIDATE" "$(json_pretooluse ExitPlanMode)"
rm -f "$TEMP_PLAN"
rm -f "${CLAUDE_PROJECT_DIR:-.}/.sep-exempt" 2>/dev/null; rm -f ".sep-exempt"
assert_output_not_contains "NO SEP REFERENCE" && pass
teardown

# ══════════════════════════════════════════════════════════════════
# GROUP 10: guard_destructive_bash.sh
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 10: guard_destructive_bash.sh ──${NC}\n"

GUARD="${SCRIPTS_DIR}/guard_destructive_bash.sh"

# 10.1 --no-verify → deny
begin_test "10.1 --no-verify → deny"
setup
run_hook "$GUARD" "$(json_bash_pretooluse "git commit --no-verify -m 'skip hooks'")"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'deny'; then
    assert_output_contains "no-verify" && pass
fi
teardown

# 10.2 git push --force → deny
begin_test "10.2 git push --force → deny"
setup
run_hook "$GUARD" "$(json_bash_pretooluse "git push --force origin main")"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'deny'; then
    assert_output_contains "push --force" && pass
fi
teardown

# 10.3 git push -f → deny
begin_test "10.3 git push -f → deny"
setup
run_hook "$GUARD" "$(json_bash_pretooluse "git push origin main -f")"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'deny'; then
    assert_output_contains "push --force" && pass
fi
teardown

# 10.4 git branch -D → deny
begin_test "10.4 git branch -D → deny"
setup
run_hook "$GUARD" "$(json_bash_pretooluse "git branch -D feature-branch")"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'deny'; then
    assert_output_contains "branch -D" && pass
fi
teardown

# 10.5 git stash drop → deny
begin_test "10.5 git stash drop → deny"
setup
run_hook "$GUARD" "$(json_bash_pretooluse "git stash drop")"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'deny'; then
    assert_output_contains "stash drop" && pass
fi
teardown

# 10.6 git stash clear → deny
begin_test "10.6 git stash clear → deny"
setup
run_hook "$GUARD" "$(json_bash_pretooluse "git stash clear")"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'deny'; then
    assert_output_contains "stash drop" && pass
fi
teardown

# 10.7 git commit --amend → deny
begin_test "10.7 git commit --amend → deny"
setup
run_hook "$GUARD" "$(json_bash_pretooluse "git commit --amend -m 'rewrite history'")"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'deny'; then
    assert_output_contains "amend" && pass
fi
teardown

# 10.8 curl | bash → deny
begin_test "10.8 curl | bash → deny"
setup
run_hook "$GUARD" "$(json_bash_pretooluse "curl http://example.com/install.sh | bash")"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'deny'; then
    assert_output_contains "Pipe-to-shell" && pass
fi
teardown

# 10.12 Chained: safe && destructive → deny
begin_test "10.12 safe && git push --force → deny"
setup
run_hook "$GUARD" "$(json_bash_pretooluse "ls -la && git push --force origin main")"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'deny'; then
    assert_output_contains "push --force" && pass
fi
teardown

# 10.13 Conditional: git checkout -- with uncommitted changes → deny
begin_test "10.13 git checkout -- in dirty repo → deny"
setup
# Create a temp git repo with uncommitted changes
GUARD_TMPDIR=$(mktemp -d)
(
    cd "$GUARD_TMPDIR"
    git init -q
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "init"
    echo "modified" > file.txt
)
# Run the guard from the dirty repo dir so git status sees uncommitted changes
HOOK_OUTPUT=""
HOOK_EXIT=0
HOOK_OUTPUT=$(echo "$(json_bash_pretooluse "git checkout -- file.txt")" | (cd "$GUARD_TMPDIR" && bash "$GUARD" 2>/dev/null)) || HOOK_EXIT=$?
rm -rf "$GUARD_TMPDIR"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'deny'; then
    assert_output_contains "uncommitted" && pass
fi
teardown

# 10.14 Conditional: git checkout -- in clean repo → allow
begin_test "10.14 git checkout -- in clean repo → allow"
setup
GUARD_TMPDIR=$(mktemp -d)
(
    cd "$GUARD_TMPDIR"
    git init -q
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "init"
)
HOOK_OUTPUT=""
HOOK_EXIT=0
HOOK_OUTPUT=$(echo "$(json_bash_pretooluse "git checkout -- file.txt")" | (cd "$GUARD_TMPDIR" && bash "$GUARD" 2>/dev/null)) || HOOK_EXIT=$?
rm -rf "$GUARD_TMPDIR"
assert_exit_code 0 && assert_output_not_contains '"deny"' && pass
teardown

# 10.15 Conditional: git reset --hard in dirty repo → deny
begin_test "10.15 git reset --hard in dirty repo → deny"
setup
GUARD_TMPDIR=$(mktemp -d)
(
    cd "$GUARD_TMPDIR"
    git init -q
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "init"
    echo "modified" > file.txt
)
HOOK_OUTPUT=""
HOOK_EXIT=0
HOOK_OUTPUT=$(echo "$(json_bash_pretooluse "git reset --hard")" | (cd "$GUARD_TMPDIR" && bash "$GUARD" 2>/dev/null)) || HOOK_EXIT=$?
rm -rf "$GUARD_TMPDIR"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'deny'; then
    assert_output_contains "uncommitted" && pass
fi
teardown

# 10.16 wget | sh → deny
begin_test "10.16 wget | sh → deny"
setup
run_hook "$GUARD" "$(json_bash_pretooluse "wget -O- http://example.com/setup | sh")"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'deny'; then
    assert_output_contains "Pipe-to-shell" && pass
fi
teardown

# 10.17 git restore (not --staged) in dirty repo → deny
begin_test "10.17 git restore in dirty repo → deny"
setup
GUARD_TMPDIR=$(mktemp -d)
(
    cd "$GUARD_TMPDIR"
    git init -q
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "init"
    echo "modified" > file.txt
)
HOOK_OUTPUT=""
HOOK_EXIT=0
HOOK_OUTPUT=$(echo "$(json_bash_pretooluse "git restore file.txt")" | (cd "$GUARD_TMPDIR" && bash "$GUARD" 2>/dev/null)) || HOOK_EXIT=$?
rm -rf "$GUARD_TMPDIR"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'deny'; then
    assert_output_contains "uncommitted" && pass
fi
teardown

# ══════════════════════════════════════════════════════════════════
# GROUP 11: Two-tier validation (unit + E2E)
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 11: Two-tier validation (unit + E2E) ──${NC}\n"

TRACK_VAL="${SCRIPTS_DIR}/track_validation.sh"
RECORD_VAL="${SCRIPTS_DIR}/record_validation.sh"

# 11.1 Unit test alone sets validated_unit but does NOT clear dirty
begin_test "11.1 Unit test alone → validated_unit set, dirty remains"
setup
echo "unit test run" > "${CLAUDE_TEST_PERSIST_DIR}/dirty"
run_hook "$TRACK_VAL" "$(json_bash_pretooluse "npm test")"
assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/validated_unit" "validated_unit marker" \
    && assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/dirty" "dirty still present" \
    && pass
teardown

# 11.2 E2E test alone sets validated_e2e but does NOT clear dirty
begin_test "11.2 E2E test alone → validated_e2e set, dirty remains"
setup
echo "e2e test run" > "${CLAUDE_TEST_PERSIST_DIR}/dirty"
run_hook "$TRACK_VAL" "$(json_bash_pretooluse "npm run test:e2e")"
assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/validated_e2e" "validated_e2e marker" \
    && assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/dirty" "dirty still present" \
    && pass
teardown

# 11.3 Both unit + E2E tests → dirty cleared
begin_test "11.3 Unit + E2E together → dirty cleared"
setup
echo "both tests" > "${CLAUDE_TEST_PERSIST_DIR}/dirty"
run_hook "$TRACK_VAL" "$(json_bash_pretooluse "pytest")"
if assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/dirty" "dirty after unit only"; then
    run_hook "$TRACK_VAL" "$(json_bash_pretooluse "pytest --e2e")"
    assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/dirty" "dirty cleared after both" \
        && assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/validated_unit" "validated_unit cleaned up" \
        && assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/validated_e2e" "validated_e2e cleaned up" \
        && pass
fi
teardown

# 11.4 E2E keywords detected: cypress, playwright, selenium, integration, e2e flag
begin_test "11.4 E2E keyword detection (multiple patterns)"
setup
echo "keyword test" > "${CLAUDE_TEST_PERSIST_DIR}/dirty"
run_hook "$TRACK_VAL" "$(json_bash_pretooluse "npx cypress run")"
assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/validated_e2e" "cypress → e2e marker" \
    && pass
teardown

begin_test "11.5 E2E keyword: playwright"
setup
echo "keyword test" > "${CLAUDE_TEST_PERSIST_DIR}/dirty"
run_hook "$TRACK_VAL" "$(json_bash_pretooluse "npx playwright test")"
assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/validated_e2e" "playwright → e2e marker" \
    && pass
teardown

begin_test "11.6 E2E keyword: --integration flag"
setup
echo "keyword test" > "${CLAUDE_TEST_PERSIST_DIR}/dirty"
run_hook "$TRACK_VAL" "$(json_bash_pretooluse "npm test -- --integration")"
assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/validated_e2e" "integration flag → e2e marker" \
    && pass
teardown

# 11.7 record_validation.sh without --force → rejected
begin_test "11.7 record_validation.sh without flag → rejected"
setup
echo "manual test" > "${CLAUDE_TEST_PERSIST_DIR}/dirty"
HOOK_OUTPUT=""
HOOK_EXIT=0
HOOK_OUTPUT=$(bash "$RECORD_VAL" "manual check" 2>&1) || HOOK_EXIT=$?
assert_exit_code 1 \
    && assert_output_contains "requires a flag" \
    && assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/dirty" "dirty NOT cleared" \
    && pass
teardown

# 11.8 record_validation.sh --command blocks when command is not approved
begin_test "11.8 record_validation.sh --command blocks when objective proof is unapproved"
setup
echo "command test" > "${CLAUDE_TEST_PERSIST_DIR}/dirty"
echo "hash-123" > "${CLAUDE_TEST_PERSIST_DIR}/plan_hash"
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/objective_verification_required"
cat > "${CLAUDE_TEST_PERSIST_DIR}/objective_verification" <<'EOF'
Run `python verify_real_system.py` against the live service and confirm the objective works.
EOF
echo "2026-03-10T00:00:00Z pytest -k unit" > "${CLAUDE_TEST_PERSIST_DIR}/validation_log"
HOOK_OUTPUT=""
HOOK_EXIT=0
HOOK_OUTPUT=$(bash "$RECORD_VAL" --command "pytest -k unit" 2>&1) || HOOK_EXIT=$?
assert_exit_code 1 \
    && assert_output_contains "not approved" \
    && assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/dirty" "dirty still present" \
    && pass
teardown

# 11.9 record_validation.sh --command records objective proof for approved command
begin_test "11.9 record_validation.sh --command records approved objective proof"
setup
echo "objective proof" > "${CLAUDE_TEST_PERSIST_DIR}/dirty"
echo "hash-123" > "${CLAUDE_TEST_PERSIST_DIR}/plan_hash"
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/objective_verification_required"
cat > "${CLAUDE_TEST_PERSIST_DIR}/objective_verification" <<'EOF'
Run `python verify_real_system.py` against the live service and confirm the objective works.
EOF
echo "2026-03-10T00:00:00Z python verify_real_system.py" > "${CLAUDE_TEST_PERSIST_DIR}/validation_log"
HOOK_OUTPUT=""
HOOK_EXIT=0
HOOK_OUTPUT=$(bash "$RECORD_VAL" --command "python verify_real_system.py" 2>&1) || HOOK_EXIT=$?
assert_exit_code 0 \
    && assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/dirty" "dirty cleared" \
    && assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/objective_verified" "objective_verified set" \
    && assert_file_contains "${CLAUDE_TEST_PERSIST_DIR}/objective_verified_evidence" "python verify_real_system.py" \
    && assert_file_contains "${CLAUDE_TEST_PERSIST_DIR}/validation_log" "OBJECTIVE VERIFIED" \
    && pass
teardown

# 11.10 record_validation.sh --manual leaves dirty and sets pending marker
begin_test "11.10 record_validation.sh --manual sets pending without clearing dirty"
setup
echo "manual pending" > "${CLAUDE_TEST_PERSIST_DIR}/dirty"
echo "hash-123" > "${CLAUDE_TEST_PERSIST_DIR}/plan_hash"
HOOK_OUTPUT=""
HOOK_EXIT=0
HOOK_OUTPUT=$(bash "$RECORD_VAL" --manual "user must verify the live endpoint" 2>&1) || HOOK_EXIT=$?
assert_exit_code 0 \
    && assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/dirty" "dirty still present" \
    && assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/validate_pending" "validate_pending set" \
    && assert_file_contains "${CLAUDE_TEST_PERSIST_DIR}/validate_pending_hash" "hash-123" \
    && pass
teardown

# 11.11 No dirty flag → validation still records markers (no error)
begin_test "11.11 No dirty → unit test still sets validated_unit"
setup
# No dirty flag set — should still record the tier marker without error
run_hook "$TRACK_VAL" "$(json_bash_pretooluse "npm test")"
assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/validated_unit" "validated_unit set even without dirty" \
    && assert_exit_code 0 \
    && pass
teardown

# 11.12 E2E before unit also works (order doesn't matter)
begin_test "11.12 E2E first, then unit → dirty cleared"
setup
echo "order test" > "${CLAUDE_TEST_PERSIST_DIR}/dirty"
run_hook "$TRACK_VAL" "$(json_bash_pretooluse "npx playwright test")"
if assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/dirty" "dirty after e2e only"; then
    run_hook "$TRACK_VAL" "$(json_bash_pretooluse "cargo test")"
    assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/dirty" "dirty cleared after both (reverse order)" \
        && pass
fi
teardown

# 11.13 clear_approval.sh and accept_outcome.sh clean up tier markers
begin_test "11.13 clear_approval.sh cleans up tier markers"
setup
echo "npm test" > "${CLAUDE_TEST_PERSIST_DIR}/validated_unit"
echo "npx cypress run" > "${CLAUDE_TEST_PERSIST_DIR}/validated_e2e"
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/approved"
echo "0" > "${CLAUDE_TEST_PERSIST_DIR}/objective_verification_required"
run_hook "${SCRIPTS_DIR}/clear_approval.sh" ""
assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/validated_unit" "validated_unit cleaned" \
    && assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/validated_e2e" "validated_e2e cleaned" \
    && pass
teardown

begin_test "11.14 accept_outcome.sh cleans up tier markers"
setup
echo "npm test" > "${CLAUDE_TEST_PERSIST_DIR}/validated_unit"
echo "npx cypress run" > "${CLAUDE_TEST_PERSIST_DIR}/validated_e2e"
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/approved"
echo "0" > "${CLAUDE_TEST_PERSIST_DIR}/objective_verification_required"
run_hook "${SCRIPTS_DIR}/accept_outcome.sh" ""
assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/validated_unit" "validated_unit cleaned" \
    && assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/validated_e2e" "validated_e2e cleaned" \
    && pass
teardown

# ══════════════════════════════════════════════════════════════════
# GROUP 12: TDD red-green enforcement
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 12: TDD red-green enforcement ──${NC}\n"

REQUIRE="${SCRIPTS_DIR}/require_plan_approval.sh"
TRACK_FAIL="${SCRIPTS_DIR}/track_test_failure.sh"

# 12.1 Production file edit blocked when tests_failed absent
begin_test "12.1 Production edit blocked without tests_failed"
setup
TEMP_PLAN_12="${TEST_TMPDIR}/plan.md"
write_plan \
    "$TEMP_PLAN_12" \
    "Implements SEP-201 by testing that production edits are blocked before the red phase." \
    "- /src/app.ts" \
    "Production edits are blocked until a failing test proves the new behavior is missing." \
    "Per /Users/shingi/.claude/CLAUDE.md, production edits must stay behind the red-phase TDD gate." \
    "I read the current approval and TDD gate scripts and verified this code-change plan needs both approval metadata and objective verification text." \
    "Run pytest against the real implementation path and confirm the objective works after the code change."
seed_approval_bundle_from_plan "$TEMP_PLAN_12"
# No tests_failed marker
run_hook "$REQUIRE" "$(json_pretooluse Edit /src/app.ts)"
assert_json_field '.hookSpecificOutput.permissionDecision' 'deny' \
    && assert_output_contains "TDD ENFORCEMENT" \
    && pass
teardown

# 12.2 Test file edit always allowed (even without tests_failed)
begin_test "12.2 Test file edit allowed without tests_failed"
setup
TEMP_PLAN_12="${TEST_TMPDIR}/plan.md"
write_plan \
    "$TEMP_PLAN_12" \
    "Implements SEP-202 by confirming test files stay editable before the red phase." \
    "- /src/test_app.py" \
    "Test files pass through the approval gate without requiring a prior failing test." \
    "Per /Users/shingi/.claude/CLAUDE.md, test files are always editable during the red phase." \
    "I read the current approval and TDD scripts and verified test-file patterns bypass the production-file TDD gate." \
    "Run pytest against the real implementation path and confirm the objective works after the code change."
seed_approval_bundle_from_plan "$TEMP_PLAN_12"
run_hook "$REQUIRE" "$(json_pretooluse Edit /src/test_app.py)"
assert_json_field '.hookSpecificOutput.permissionDecision' 'allow' && pass
teardown

# 12.3 track_test_failure.sh sets tests_failed on failing test command
begin_test "12.3 track_test_failure.sh sets tests_failed on test failure"
setup
run_hook "$TRACK_FAIL" "$(json_bash_pretooluse "npm test")"
assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/tests_failed" "tests_failed marker" \
    && pass
teardown

# 12.4 track_test_failure.sh ignores non-test commands
begin_test "12.4 track_test_failure.sh ignores non-test commands"
setup
run_hook "$TRACK_FAIL" "$(json_bash_pretooluse "ls -la /tmp")"
assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/tests_failed" "no tests_failed for ls" \
    && pass
teardown

# 12.5 After tests_failed set, production file edit allowed
begin_test "12.5 Production edit allowed after tests_failed"
setup
TEMP_PLAN_12="${TEST_TMPDIR}/plan.md"
write_plan \
    "$TEMP_PLAN_12" \
    "Implements SEP-203 by allowing production edits after the red phase and test review." \
    "- /src/app.ts" \
    "Production edits are allowed only after the failing test and user review markers exist." \
    "Per /Users/shingi/.claude/CLAUDE.md, the red phase and the human test-review gate must both complete before production edits." \
    "I read the current approval and TDD gate scripts and verified both tests_failed and tests_reviewed are required before production edits pass." \
    "Run pytest against the real implementation path and confirm the objective works after the code change."
seed_approval_bundle_from_plan "$TEMP_PLAN_12"
mark_tdd_ready
run_hook "$REQUIRE" "$(json_pretooluse Edit /src/app.ts)"
assert_json_field '.hookSpecificOutput.permissionDecision' 'allow' && pass
teardown

# 12.6 Documentation files bypass TDD gate
begin_test "12.6 Markdown files bypass TDD gate"
setup
TEMP_PLAN_12="${TEST_TMPDIR}/plan.md"
write_plan \
    "$TEMP_PLAN_12" \
    "Implements SEP-204 by proving documentation files bypass the production-file TDD gate." \
    "- /docs/README.md" \
    "Documentation edits bypass the red-phase production gate and remain scoped by approval." \
    "Per /Users/shingi/.claude/CLAUDE.md, markdown files are exempt from the production-file TDD sequencing rules." \
    "I read the current approval and TDD scripts and verified markdown files bypass the production-file gate while still requiring approval scope." \
    "Review the resulting documentation in the real workspace and confirm the approved objective is met."
seed_approval_bundle_from_plan "$TEMP_PLAN_12"
# No tests_failed marker
run_hook "$REQUIRE" "$(json_pretooluse Edit /docs/README.md)"
assert_json_field '.hookSpecificOutput.permissionDecision' 'allow' && pass
teardown

# 12.7 Full red-green sequence: write test → run (fail) → edit prod → run (pass) → validated
begin_test "12.7 Full red-green-validate sequence"
setup
TEMP_PLAN_12="${TEST_TMPDIR}/plan.md"
write_plan \
    "$TEMP_PLAN_12" \
    "Implements SEP-205 by exercising the current red phase, review gate, and production edit workflow end to end." \
    $'- /src/test_app.py\n- /src/app.py' \
    "The full TDD workflow enforces red phase, human test review, and then production editing." \
    "Per /Users/shingi/.claude/CLAUDE.md, the TDD workflow includes both the red phase and the user review checkpoint before production edits." \
    "I read the current approval, failure-tracking, and TDD gate scripts and verified the workflow requires test editing, a failing test, user review, and then production edits." \
    "Run pytest against the real implementation path and confirm the objective works after the code change."
seed_approval_bundle_from_plan "$TEMP_PLAN_12"
# Step 1: Test file edit allowed (no tests_failed needed)
run_hook "$REQUIRE" "$(json_pretooluse Edit /src/test_app.py)"
STEP1_OK=false
[[ "$(echo "$HOOK_OUTPUT" | jq -r '.hookSpecificOutput.permissionDecision')" == "allow" ]] && STEP1_OK=true
# Step 2: Production file blocked (no tests_failed yet)
run_hook "$REQUIRE" "$(json_pretooluse Edit /src/app.py)"
STEP2_OK=false
echo "$HOOK_OUTPUT" | grep -q "TDD ENFORCEMENT" && STEP2_OK=true
# Step 3: Test fails (red) → sets tests_failed
run_hook "$TRACK_FAIL" "$(json_bash_pretooluse "pytest")"
STEP3_OK=false
[[ -f "${CLAUDE_TEST_PERSIST_DIR}/tests_failed" ]] && STEP3_OK=true
# Step 4: User reviews the red-phase tests
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/tests_reviewed"
# Step 5: Production file now allowed
run_hook "$REQUIRE" "$(json_pretooluse Edit /src/app.py)"
STEP4_OK=false
[[ "$(echo "$HOOK_OUTPUT" | jq -r '.hookSpecificOutput.permissionDecision')" == "allow" ]] && STEP4_OK=true
if $STEP1_OK && $STEP2_OK && $STEP3_OK && $STEP4_OK; then
    pass
else
    fail "Steps: 1=$STEP1_OK 2=$STEP2_OK 3=$STEP3_OK 4=$STEP4_OK"
fi
teardown

# 12.8 Fake test sequence blocked: write test → run (pass immediately) → prod edit blocked
begin_test "12.8 Fake test (passes immediately) does NOT unlock prod edit"
setup
TEMP_PLAN_12="${TEST_TMPDIR}/plan.md"
write_plan \
    "$TEMP_PLAN_12" \
    "Implements SEP-206 by proving passing tests alone do not unlock production editing." \
    $'- /src/test_app.py\n- /src/app.py' \
    "A passing test without a prior failure leaves production editing blocked by the red-phase gate." \
    "Per /Users/shingi/.claude/CLAUDE.md, tests that pass immediately do not unlock production editing." \
    "I read the current validation and TDD scripts and verified only PostToolUseFailure sets tests_failed for the red phase." \
    "Run pytest against the real implementation path and confirm the objective works after the code change."
seed_approval_bundle_from_plan "$TEMP_PLAN_12"
# Test passes (PostToolUse, not PostToolUseFailure) — track_validation runs, NOT track_test_failure
TRACK_VAL_12="${SCRIPTS_DIR}/track_validation.sh"
run_hook "$TRACK_VAL_12" "$(json_bash_pretooluse "pytest")"
# tests_failed should NOT be set (only PostToolUseFailure sets it)
assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/tests_failed" "no tests_failed from passing test"
# Production edit should be blocked
run_hook "$REQUIRE" "$(json_pretooluse Edit /src/app.py)"
assert_json_field '.hookSpecificOutput.permissionDecision' 'deny' \
    && assert_output_contains "TDD ENFORCEMENT" \
    && pass
teardown

# 12.9 Diagnostic mode NOT triggered when approved plan exists
begin_test "12.9 Diagnostic mode skipped during active implementation"
setup
CHECK_CMD="${SCRIPTS_DIR}/check_clear_approval_command.sh"
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/approved"
# Simulate a diagnostic-sounding prompt during implementation
DIAG_JSON=$(jq -n '{"session_id":"test-session-001","prompt":"why are my tests failing?"}')
run_hook "$CHECK_CMD" "$DIAG_JSON"
assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/diagnostic_mode" "no diagnostic_mode during implementation" \
    && pass
teardown

# 12.10 Diagnostic mode still triggers when no approved plan exists
begin_test "12.10 Diagnostic mode triggers without approved plan"
setup
CHECK_CMD="${SCRIPTS_DIR}/check_clear_approval_command.sh"
# No approved marker — diagnostic should trigger
DIAG_JSON=$(jq -n '{"session_id":"test-session-001","prompt":"why are my tests failing?"}')
run_hook "$CHECK_CMD" "$DIAG_JSON"
assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/diagnostic_mode" "diagnostic_mode set" \
    && pass
teardown

# 12.11 Test file patterns: _test.go, .spec.ts, __tests__/ dir
begin_test "12.11 Various test file patterns bypass TDD gate"
setup
TEMP_PLAN_12="${TEST_TMPDIR}/plan.md"
write_plan \
    "$TEMP_PLAN_12" \
    "Implements SEP-207 by checking that the current test-file patterns bypass the production-file gate." \
    $'- /src/app_test.go\n- /src/app.spec.ts\n- /src/__tests__/app.js' \
    "All recognized test-file patterns remain editable during the red phase." \
    "Per /Users/shingi/.claude/CLAUDE.md, recognized test-file patterns bypass the production-file TDD gate." \
    "I read the current require_plan_approval.sh matcher list and verified these test-file patterns should all pass the TDD gate." \
    "Run the relevant test command against the real implementation path and confirm the approved objective is met."
seed_approval_bundle_from_plan "$TEMP_PLAN_12"
ALL_PASS=true
for TEST_PATH in "/src/app_test.go" "/src/app.spec.ts" "/src/__tests__/app.js"; do
    run_hook "$REQUIRE" "$(json_pretooluse Edit "$TEST_PATH")"
    if [[ "$(echo "$HOOK_OUTPUT" | jq -r '.hookSpecificOutput.permissionDecision')" != "allow" ]]; then
        ALL_PASS=false
        fail "TDD gate blocked test file: $TEST_PATH"
        break
    fi
done
$ALL_PASS && pass
teardown

# 12.12 track_test_failure.sh logs failure to validation_log
begin_test "12.12 track_test_failure.sh appends FAILED to validation_log"
setup
run_hook "$TRACK_FAIL" "$(json_bash_pretooluse "pytest")"
assert_file_contains "${CLAUDE_TEST_PERSIST_DIR}/validation_log" "FAILED: pytest" \
    && pass
teardown

# 12.13 tests_failed cleared when two-tier validation completes
begin_test "12.13 tests_failed cleared on two-tier validation completion"
setup
echo "red phase" > "${CLAUDE_TEST_PERSIST_DIR}/tests_failed"
echo "dirty" > "${CLAUDE_TEST_PERSIST_DIR}/dirty"
TRACK_VAL_12="${SCRIPTS_DIR}/track_validation.sh"
# Unit pass
run_hook "$TRACK_VAL_12" "$(json_bash_pretooluse "pytest")"
assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/tests_failed" "tests_failed still present after unit only"
# E2E pass — should clear tests_failed along with dirty
run_hook "$TRACK_VAL_12" "$(json_bash_pretooluse "pytest --e2e")"
assert_file_missing "${CLAUDE_TEST_PERSIST_DIR}/tests_failed" "tests_failed cleared after both tiers" \
    && pass
teardown

# 12.14 record_validation.sh --force is blocked
begin_test "12.14 record_validation.sh --force is blocked"
setup
echo "refactor" > "${CLAUDE_TEST_PERSIST_DIR}/dirty"
HOOK_OUTPUT=""
HOOK_EXIT=0
HOOK_OUTPUT=$(bash "${SCRIPTS_DIR}/record_validation.sh" --force "refactor: no new behavior" 2>&1) || HOOK_EXIT=$?
assert_exit_code 1 \
    && assert_output_contains "not permitted" \
    && assert_file_exists "${CLAUDE_TEST_PERSIST_DIR}/dirty" "dirty still present" \
    && pass
teardown

# 12.19 validate_plan_quality requires Objective Verification for code changes
begin_test "12.19 validate_plan_quality blocks missing Objective Verification"
setup
PLAN_FILE="${HOME}/.claude/plans/_test_objective_verification_required.md"
mkdir -p "${HOME}/.claude/plans"
cat > "$PLAN_FILE" <<'PLAN'
## Objective
Validate that code-change plans require objective verification.

## Scope
- /src/app.py

## Success Criteria
Plan is rejected without objective verification.

## Justification
Testing the objective verification gate against plan approval.

## Validation
Local hook test only.
PLAN
echo "$(date +%s)" > "${CLAUDE_TEST_PERSIST_DIR}/planning_started_at"
run_hook "${SCRIPTS_DIR}/validate_plan_quality.sh" "$(json_pretooluse ExitPlanMode)"
assert_json_field '.hookSpecificOutput.permissionDecision' 'deny' \
    && assert_output_contains "Objective Verification" \
    && pass
rm -f "$PLAN_FILE"
teardown

# 12.20 clear_approval.sh blocks when objective proof is missing
begin_test "12.20 clear_approval.sh blocks without objective proof"
setup
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/approved"
echo "hash-789" > "${CLAUDE_TEST_PERSIST_DIR}/plan_hash"
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/objective_verification_required"
cat > "${CLAUDE_TEST_PERSIST_DIR}/objective_verification" <<'EOF'
Run `python verify_real_system.py` and confirm the objective works.
EOF
HOOK_OUTPUT=""
HOOK_EXIT=0
HOOK_OUTPUT=$(bash "${SCRIPTS_DIR}/clear_approval.sh" 2>&1) || HOOK_EXIT=$?
assert_exit_code 1 \
    && assert_output_contains "not been verified" \
    && pass
teardown

# 12.21 accept_outcome preflight requires second user confirmation for bypass
begin_test "12.21 accept_outcome preflight uses two-step user bypass"
setup
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/approved"
echo "hash-999" > "${CLAUDE_TEST_PERSIST_DIR}/plan_hash"
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/objective_verification_required"
cat > "${CLAUDE_TEST_PERSIST_DIR}/objective_verification" <<'EOF'
Run `python verify_real_system.py` and confirm the objective works.
EOF
HOOK_OUTPUT=""
HOOK_EXIT=0
HOOK_OUTPUT=$(bash "${SCRIPTS_DIR}/accept_outcome.sh" --preflight 2>&1) || HOOK_EXIT=$?
STEP1_OK=false
if [[ "$HOOK_EXIT" -eq 1 ]] && [[ -f "${CLAUDE_TEST_PERSIST_DIR}/accept_bypass_pending" ]]; then
    STEP1_OK=true
fi
HOOK_OUTPUT=""
HOOK_EXIT=0
HOOK_OUTPUT=$(bash "${SCRIPTS_DIR}/accept_outcome.sh" --preflight 2>&1) || HOOK_EXIT=$?
STEP2_OK=false
if [[ "$HOOK_EXIT" -eq 0 ]] && [[ -f "${CLAUDE_TEST_PERSIST_DIR}/user_bypass" ]]; then
    STEP2_OK=true
fi
if $STEP1_OK && $STEP2_OK; then
    pass
else
    fail "preflight steps failed: first=$STEP1_OK second=$STEP2_OK"
fi
teardown

# ══════════════════════════════════════════════════════════════════
# Section 14: Workflow state injection via UserPromptSubmit (SEP-006)
# ══════════════════════════════════════════════════════════════════
echo ""
echo "═══ Section 14: Workflow State Injection (SEP-006) ═══"

CHECK_CMD_14="${SCRIPTS_DIR}/check_clear_approval_command.sh"
NORMAL_PROMPT='{"session_id":"test-session-001","prompt":"continue implementing"}'

# 14.1 Workflow state injected when plan is approved
begin_test "14.1 Workflow state injected when plan is approved"
setup
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/approved"
echo "Build the widget" > "${CLAUDE_TEST_PERSIST_DIR}/objective"
echo "/src/widget.py" > "${CLAUDE_TEST_PERSIST_DIR}/scope"
echo "Widget works end to end" > "${CLAUDE_TEST_PERSIST_DIR}/criteria"
run_hook "$CHECK_CMD_14" "$NORMAL_PROMPT"
CONTEXT=$(echo "$HOOK_OUTPUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
if echo "$CONTEXT" | grep -q "WORKFLOW STATE" && \
   echo "$CONTEXT" | grep -q "APPROVED" && \
   echo "$CONTEXT" | grep -q "Build the widget"; then
    pass
else
    fail "Expected WORKFLOW STATE with APPROVED and objective (got: ${CONTEXT:0:300})"
fi
teardown

# 14.2 Workflow state shows TDD phase: tests written, not yet reviewed
begin_test "14.2 Workflow state shows TDD red phase"
setup
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/approved"
echo "Build the widget" > "${CLAUDE_TEST_PERSIST_DIR}/objective"
echo "/src/widget.py" > "${CLAUDE_TEST_PERSIST_DIR}/scope"
echo "Widget works" > "${CLAUDE_TEST_PERSIST_DIR}/criteria"
echo "failed at $(date)" > "${CLAUDE_TEST_PERSIST_DIR}/tests_failed"
run_hook "$CHECK_CMD_14" "$NORMAL_PROMPT"
CONTEXT=$(echo "$HOOK_OUTPUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
if echo "$CONTEXT" | grep -qi "tests.*fail\|red phase\|tests written"; then
    pass
else
    fail "Expected TDD red phase indicator (got: ${CONTEXT:0:300})"
fi
teardown

# 14.3 Workflow state shows tests reviewed / ready to implement
begin_test "14.3 Workflow state shows tests reviewed"
setup
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/approved"
echo "Build the widget" > "${CLAUDE_TEST_PERSIST_DIR}/objective"
echo "/src/widget.py" > "${CLAUDE_TEST_PERSIST_DIR}/scope"
echo "Widget works" > "${CLAUDE_TEST_PERSIST_DIR}/criteria"
echo "failed" > "${CLAUDE_TEST_PERSIST_DIR}/tests_failed"
echo "approved" > "${CLAUDE_TEST_PERSIST_DIR}/tests_reviewed"
run_hook "$CHECK_CMD_14" "$NORMAL_PROMPT"
CONTEXT=$(echo "$HOOK_OUTPUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
if echo "$CONTEXT" | grep -qi "tests reviewed\|ready to implement\|IMPLEMENTING"; then
    pass
else
    fail "Expected tests-reviewed / implementing indicator (got: ${CONTEXT:0:300})"
fi
teardown

# 14.4 Workflow state shows edit count when edits have been made
begin_test "14.4 Workflow state shows edit count"
setup
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/approved"
echo "Build the widget" > "${CLAUDE_TEST_PERSIST_DIR}/objective"
echo "/src/widget.py" > "${CLAUDE_TEST_PERSIST_DIR}/scope"
echo "Widget works" > "${CLAUDE_TEST_PERSIST_DIR}/criteria"
echo "5" > "${CLAUDE_TEST_PERSIST_DIR}/edit_count"
echo "failed" > "${CLAUDE_TEST_PERSIST_DIR}/tests_failed"
echo "approved" > "${CLAUDE_TEST_PERSIST_DIR}/tests_reviewed"
run_hook "$CHECK_CMD_14" "$NORMAL_PROMPT"
CONTEXT=$(echo "$HOOK_OUTPUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
if echo "$CONTEXT" | grep -q "5"; then
    pass
else
    fail "Expected edit count 5 in state (got: ${CONTEXT:0:300})"
fi
teardown

# 14.5 Workflow state shows planning phase when in plan mode
begin_test "14.5 Workflow state shows planning phase"
setup
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/planning"
run_hook "$CHECK_CMD_14" "$NORMAL_PROMPT"
CONTEXT=$(echo "$HOOK_OUTPUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
if echo "$CONTEXT" | grep -qi "PLANNING\|plan mode"; then
    pass
else
    fail "Expected PLANNING indicator (got: ${CONTEXT:0:300})"
fi
teardown

# 14.6 Workflow state includes plan file path
begin_test "14.6 Workflow state includes plan file path"
setup
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/approved"
echo "Build the widget" > "${CLAUDE_TEST_PERSIST_DIR}/objective"
echo "/src/widget.py" > "${CLAUDE_TEST_PERSIST_DIR}/scope"
echo "Widget works" > "${CLAUDE_TEST_PERSIST_DIR}/criteria"
echo "/tmp/test-plan.md" > "${CLAUDE_TEST_PERSIST_DIR}/plan_file"
run_hook "$CHECK_CMD_14" "$NORMAL_PROMPT"
CONTEXT=$(echo "$HOOK_OUTPUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
if echo "$CONTEXT" | grep -q "/tmp/test-plan.md"; then
    pass
else
    fail "Expected plan file path in state (got: ${CONTEXT:0:300})"
fi
teardown

# 14.7 No workflow state block when no plan and no planning
begin_test "14.7 No workflow state when idle (no plan, no planning)"
setup
run_hook "$CHECK_CMD_14" "$NORMAL_PROMPT"
CONTEXT=$(echo "$HOOK_OUTPUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
if echo "$CONTEXT" | grep -q "WORKFLOW STATE"; then
    fail "Should not inject WORKFLOW STATE when idle (got: ${CONTEXT:0:300})"
else
    pass
fi
teardown

# 14.8 Workflow state shows dirty flag
begin_test "14.8 Workflow state shows dirty flag"
setup
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/approved"
echo "Build the widget" > "${CLAUDE_TEST_PERSIST_DIR}/objective"
echo "/src/widget.py" > "${CLAUDE_TEST_PERSIST_DIR}/scope"
echo "Widget works" > "${CLAUDE_TEST_PERSIST_DIR}/criteria"
echo "1" > "${CLAUDE_TEST_PERSIST_DIR}/dirty"
echo "failed" > "${CLAUDE_TEST_PERSIST_DIR}/tests_failed"
echo "approved" > "${CLAUDE_TEST_PERSIST_DIR}/tests_reviewed"
run_hook "$CHECK_CMD_14" "$NORMAL_PROMPT"
CONTEXT=$(echo "$HOOK_OUTPUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
if echo "$CONTEXT" | grep -qi "dirty\|validation needed\|unvalidated"; then
    pass
else
    fail "Expected dirty/validation-needed indicator (got: ${CONTEXT:0:300})"
fi
teardown

# ══════════════════════════════════════════════════════════════════
# Final report
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}══════════════════════════════════════════${NC}\n"
if [[ "$FAILED" -eq 0 ]]; then
    printf "${GREEN}ALL TESTS PASSED: %d / %d${NC}\n" "$PASSED" "$TOTAL"
else
    printf "${RED}FAILURES: %d / %d${NC}\n" "$FAILED" "$TOTAL"
    printf "\nFailed tests:\n"
    printf "$FAILURES"
fi
printf "${YELLOW}══════════════════════════════════════════${NC}\n"

exit "$FAILED"
