#!/bin/bash
# test_sep013_tdd_skill.sh — Tests for SEP-013: TDD skill improvements
#
# Verifies three behaviors that do not yet exist:
#   1. Test files bypass scope enforcement in require_plan_approval.sh
#   2. approve_plan.sh output mentions /tdd after plan approval
#   3. check_clear_approval_command.sh injects "Next: Invoke /tdd" in APPROVED phase
#      when tests_failed has not been set yet
#
# Usage: bash ~/.claude/scripts/tests/test_sep013_tdd_skill.sh

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

# ── Test harness (mirrors test_hooks.sh) ──

setup() {
    TEST_TMPDIR=$(mktemp -d)
    export HOME="${TEST_TMPDIR}/home"
    WORKFLOW_DB="${HOME}/.claude/workflow.db"
    _DB_INITIALIZED=""
    export CONV_ID="test-session-sep013"
    SESSION_ID=""
    CONVERSATION_TOKEN=""
    mkdir -p "$HOME/.claude/plans" "$HOME/.claude/shared-memory" "$HOME/.claude"
    ensure_db
    db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('$(sql_escape "$CONV_ID")', '$(pwd)');"
    db_exec "INSERT OR IGNORE INTO sessions (session_id, conversation_id) VALUES ('$(sql_escape "$CONV_ID")', '$(sql_escape "$CONV_ID")');"
    PROJECT_HASH="test"
    CONVERSATION_TOKEN="$CONV_ID"
    PERSIST_DIR="${HOME}/.claude/state/${PROJECT_HASH}/${CONV_ID}"
    PLAN_DIR="$(conversation_plan_dir)"
    mkdir -p "$PERSIST_DIR"
    mkdir -p "$PLAN_DIR"
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

assert_state_exists() {
    local key="$1"
    local label="${2:-state '$key' exists}"
    if ! state_exists "$key"; then
        fail "Expected state '$key' to exist: $label"
        return 1
    fi
    return 0
}

assert_state_not_exists() {
    local key="$1"
    local label="${2:-state '$key' missing}"
    if state_exists "$key"; then
        fail "Expected state '$key' to NOT exist: $label"
        return 1
    fi
    return 0
}

assert_output_contains() {
    local pattern="$1"
    local label="${2:-output contains '$pattern'}"
    if ! echo "$HOOK_OUTPUT" | grep -q "$pattern" 2>/dev/null; then
        fail "Output does not contain: $pattern (got: ${HOOK_OUTPUT:0:300})"
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

# ── JSON helpers ──

json_pretooluse() {
    local tool="$1"
    local file_path="${2:-}"
    local input="{}"
    if [[ -n "$file_path" ]]; then
        input=$(jq -n --arg fp "$file_path" '{"file_path":$fp}')
    fi
    jq -n --arg tool "$tool" --argjson input "$input" \
        '{"session_id":"test-session-sep013","tool_name":$tool,"tool_input":$input}'
}

json_posttooluse() {
    local tool="$1"
    jq -n --arg tool "$tool" \
        '{"session_id":"test-session-sep013","tool_name":$tool,"tool_input":{}}'
}

json_userpromptsubmit() {
    jq -n '{"session_id":"test-session-sep013","tool_name":"UserPromptSubmit","tool_input":{}}'
}

# Write a minimal but valid plan (code-change plan so it stores objective_verification)
write_plan_with_scope() {
    local plan_file="$1"
    local scope_block="$2"
    mkdir -p "$(dirname "$plan_file")"
    cat > "$plan_file" <<EOF
## Objective
Implements SEP-013 by testing that test files bypass scope enforcement for the current hook system.

## Scope
${scope_block}

## Success Criteria
Test files are never blocked by scope enforcement while non-test files outside scope remain blocked.

## Justification
Per /Users/shingi/.claude/CLAUDE.md, test files must always be editable during the red phase regardless of plan scope.

## Validation
Sources consulted: require_plan_approval.sh, common.sh, CLAUDE.md.
Evidence: current scope check at lines 93-114 has no test-file exemption.
Verified: non-test out-of-scope files are currently denied.
Known gaps: none.

## Objective Verification
Run bash test_sep013_tdd_skill.sh and confirm all tests pass.
EOF
}

seed_approval_bundle_from_plan() {
    local plan_file="$1"
    write_approval_bundle "$plan_file" >/dev/null
}

# ══════════════════════════════════════════════════════════════════
# GROUP 1: Test files bypass scope enforcement
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 1: Test files bypass scope enforcement ──${NC}\n"

REQUIRE="${SCRIPTS_DIR}/require_plan_approval.sh"

# 1.1 test_*.py should bypass scope enforcement even when not listed in scope
begin_test "1.1 test_*.py bypasses scope when not listed in plan scope"
setup
PLAN_FILE="${PLAN_DIR}/sep013-scope-plan.md"
# Scope only lists a production file — no test file in scope
write_plan_with_scope "$PLAN_FILE" "- /project/src/app.py"
seed_approval_bundle_from_plan "$PLAN_FILE"
# Mark TDD ready so we're past that gate — we're only testing scope enforcement here
state_write tests_failed "2026-03-19T00:00:00Z pytest"
state_write tests_reviewed "1"
run_hook "$REQUIRE" "$(json_pretooluse Edit /project/tests/test_app.py)"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'allow'; then
    pass
fi
teardown

# 1.2 test_*.sh should bypass scope enforcement
begin_test "1.2 test_*.sh bypasses scope when not listed in plan scope"
setup
PLAN_FILE="${PLAN_DIR}/sep013-scope-plan.md"
write_plan_with_scope "$PLAN_FILE" "- /project/src/hook.sh"
seed_approval_bundle_from_plan "$PLAN_FILE"
state_write tests_failed "2026-03-19T00:00:00Z bash"
state_write tests_reviewed "1"
run_hook "$REQUIRE" "$(json_pretooluse Edit /project/tests/test_hook.sh)"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'allow'; then
    pass
fi
teardown

# 1.3 *_test.py should bypass scope enforcement
begin_test "1.3 *_test.py bypasses scope when not listed in plan scope"
setup
PLAN_FILE="${PLAN_DIR}/sep013-scope-plan.md"
write_plan_with_scope "$PLAN_FILE" "- /project/src/app.py"
seed_approval_bundle_from_plan "$PLAN_FILE"
state_write tests_failed "2026-03-19T00:00:00Z pytest"
state_write tests_reviewed "1"
run_hook "$REQUIRE" "$(json_pretooluse Edit /project/src/app_test.py)"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'allow'; then
    pass
fi
teardown

# 1.4 *_test.go should bypass scope enforcement
begin_test "1.4 *_test.go bypasses scope when not listed in plan scope"
setup
PLAN_FILE="${PLAN_DIR}/sep013-scope-plan.md"
write_plan_with_scope "$PLAN_FILE" "- /project/src/main.go"
seed_approval_bundle_from_plan "$PLAN_FILE"
state_write tests_failed "2026-03-19T00:00:00Z go test"
state_write tests_reviewed "1"
run_hook "$REQUIRE" "$(json_pretooluse Edit /project/src/main_test.go)"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'allow'; then
    pass
fi
teardown

# 1.5 *.test.ts should bypass scope enforcement
begin_test "1.5 *.test.ts bypasses scope when not listed in plan scope"
setup
PLAN_FILE="${PLAN_DIR}/sep013-scope-plan.md"
write_plan_with_scope "$PLAN_FILE" "- /project/src/app.ts"
seed_approval_bundle_from_plan "$PLAN_FILE"
state_write tests_failed "2026-03-19T00:00:00Z npm test"
state_write tests_reviewed "1"
run_hook "$REQUIRE" "$(json_pretooluse Edit /project/src/app.test.ts)"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'allow'; then
    pass
fi
teardown

# 1.6 *.spec.ts should bypass scope enforcement
begin_test "1.6 *.spec.ts bypasses scope when not listed in plan scope"
setup
PLAN_FILE="${PLAN_DIR}/sep013-scope-plan.md"
write_plan_with_scope "$PLAN_FILE" "- /project/src/app.ts"
seed_approval_bundle_from_plan "$PLAN_FILE"
state_write tests_failed "2026-03-19T00:00:00Z npm test"
state_write tests_reviewed "1"
run_hook "$REQUIRE" "$(json_pretooluse Edit /project/src/app.spec.ts)"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'allow'; then
    pass
fi
teardown

# 1.7 *.test.js should bypass scope enforcement
begin_test "1.7 *.test.js bypasses scope when not listed in plan scope"
setup
PLAN_FILE="${PLAN_DIR}/sep013-scope-plan.md"
write_plan_with_scope "$PLAN_FILE" "- /project/src/app.js"
seed_approval_bundle_from_plan "$PLAN_FILE"
state_write tests_failed "2026-03-19T00:00:00Z npm test"
state_write tests_reviewed "1"
run_hook "$REQUIRE" "$(json_pretooluse Edit /project/src/app.test.js)"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'allow'; then
    pass
fi
teardown

# 1.8 *.spec.js should bypass scope enforcement
begin_test "1.8 *.spec.js bypasses scope when not listed in plan scope"
setup
PLAN_FILE="${PLAN_DIR}/sep013-scope-plan.md"
write_plan_with_scope "$PLAN_FILE" "- /project/src/app.js"
seed_approval_bundle_from_plan "$PLAN_FILE"
state_write tests_failed "2026-03-19T00:00:00Z npm test"
state_write tests_reviewed "1"
run_hook "$REQUIRE" "$(json_pretooluse Edit /project/src/app.spec.js)"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'allow'; then
    pass
fi
teardown

# 1.9 *.test.tsx should bypass scope enforcement
begin_test "1.9 *.test.tsx bypasses scope when not listed in plan scope"
setup
PLAN_FILE="${PLAN_DIR}/sep013-scope-plan.md"
write_plan_with_scope "$PLAN_FILE" "- /project/src/component.tsx"
seed_approval_bundle_from_plan "$PLAN_FILE"
state_write tests_failed "2026-03-19T00:00:00Z npm test"
state_write tests_reviewed "1"
run_hook "$REQUIRE" "$(json_pretooluse Edit /project/src/component.test.tsx)"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'allow'; then
    pass
fi
teardown

# 1.10 *.spec.jsx should bypass scope enforcement
begin_test "1.10 *.spec.jsx bypasses scope when not listed in plan scope"
setup
PLAN_FILE="${PLAN_DIR}/sep013-scope-plan.md"
write_plan_with_scope "$PLAN_FILE" "- /project/src/widget.jsx"
seed_approval_bundle_from_plan "$PLAN_FILE"
state_write tests_failed "2026-03-19T00:00:00Z npm test"
state_write tests_reviewed "1"
run_hook "$REQUIRE" "$(json_pretooluse Edit /project/src/widget.spec.jsx)"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'allow'; then
    pass
fi
teardown

# 1.11 File under tests/ directory should bypass scope enforcement
begin_test "1.11 File under tests/ directory bypasses scope when not listed in plan scope"
setup
PLAN_FILE="${PLAN_DIR}/sep013-scope-plan.md"
write_plan_with_scope "$PLAN_FILE" "- /project/src/app.py"
seed_approval_bundle_from_plan "$PLAN_FILE"
state_write tests_failed "2026-03-19T00:00:00Z pytest"
state_write tests_reviewed "1"
run_hook "$REQUIRE" "$(json_pretooluse Edit /project/tests/integration_test.py)"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'allow'; then
    pass
fi
teardown

# 1.12 File under test/ directory should bypass scope enforcement
begin_test "1.12 File under test/ directory bypasses scope when not listed in plan scope"
setup
PLAN_FILE="${PLAN_DIR}/sep013-scope-plan.md"
write_plan_with_scope "$PLAN_FILE" "- /project/src/app.go"
seed_approval_bundle_from_plan "$PLAN_FILE"
state_write tests_failed "2026-03-19T00:00:00Z go test"
state_write tests_reviewed "1"
run_hook "$REQUIRE" "$(json_pretooluse Edit /project/test/helpers.go)"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'allow'; then
    pass
fi
teardown

# 1.13 File under __tests__/ directory should bypass scope enforcement
begin_test "1.13 File under __tests__/ directory bypasses scope when not listed in plan scope"
setup
PLAN_FILE="${PLAN_DIR}/sep013-scope-plan.md"
write_plan_with_scope "$PLAN_FILE" "- /project/src/app.ts"
seed_approval_bundle_from_plan "$PLAN_FILE"
state_write tests_failed "2026-03-19T00:00:00Z npm test"
state_write tests_reviewed "1"
run_hook "$REQUIRE" "$(json_pretooluse Edit /project/src/__tests__/app.test.ts)"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'allow'; then
    pass
fi
teardown

# 1.14 File under spec/ directory should bypass scope enforcement
begin_test "1.14 File under spec/ directory bypasses scope when not listed in plan scope"
setup
PLAN_FILE="${PLAN_DIR}/sep013-scope-plan.md"
write_plan_with_scope "$PLAN_FILE" "- /project/src/app.rb"
seed_approval_bundle_from_plan "$PLAN_FILE"
state_write tests_failed "2026-03-19T00:00:00Z rspec"
state_write tests_reviewed "1"
run_hook "$REQUIRE" "$(json_pretooluse Edit /project/spec/app_spec.rb)"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'allow'; then
    pass
fi
teardown

# 1.15 Non-test files that are NOT in scope are still blocked
begin_test "1.15 Non-test production file out of scope is still denied"
setup
PLAN_FILE="${PLAN_DIR}/sep013-scope-plan.md"
# Scope only lists one file; the edit targets a different production file
write_plan_with_scope "$PLAN_FILE" "- /project/src/app.py"
seed_approval_bundle_from_plan "$PLAN_FILE"
state_write tests_failed "2026-03-19T00:00:00Z pytest"
state_write tests_reviewed "1"
run_hook "$REQUIRE" "$(json_pretooluse Edit /project/src/other_module.py)"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'deny'; then
    assert_output_contains "BLOCKED: File not in approved scope" && pass
fi
teardown

# 1.16 Non-test .ts file out of scope is still blocked
begin_test "1.16 Non-test .ts file out of scope is still denied"
setup
PLAN_FILE="${PLAN_DIR}/sep013-scope-plan.md"
write_plan_with_scope "$PLAN_FILE" "- /project/src/app.ts"
seed_approval_bundle_from_plan "$PLAN_FILE"
state_write tests_failed "2026-03-19T00:00:00Z npm test"
state_write tests_reviewed "1"
# This is utils.ts (not a test file) and not in scope
run_hook "$REQUIRE" "$(json_pretooluse Edit /project/src/utils.ts)"
if assert_json_field '.hookSpecificOutput.permissionDecision' 'deny'; then
    assert_output_contains "BLOCKED: File not in approved scope" && pass
fi
teardown

# 1.17 Test file scope exemption works even before tests_failed is set (red phase)
begin_test "1.17 Test file bypasses scope before tests_failed is set (writing red phase tests)"
setup
PLAN_FILE="${PLAN_DIR}/sep013-scope-plan.md"
# Scope only lists production file
write_plan_with_scope "$PLAN_FILE" "- /project/src/app.py"
seed_approval_bundle_from_plan "$PLAN_FILE"
# No tests_failed, no tests_reviewed — earliest possible point in TDD cycle
run_hook "$REQUIRE" "$(json_pretooluse Edit /project/tests/test_app.py)"
# Should be allowed by scope exemption before hitting the TDD gate
# (The TDD gate allows test files anyway, but this tests that scope doesn't block first)
if assert_json_field '.hookSpecificOutput.permissionDecision' 'allow'; then
    pass
fi
teardown

# ══════════════════════════════════════════════════════════════════
# GROUP 2: approve_plan.sh mentions /tdd after approval
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 2: approve_plan.sh output mentions /tdd ──${NC}\n"

APPROVE="${SCRIPTS_DIR}/approve_plan.sh"

# 2.1 approve_plan.sh output contains /tdd when approval bundle is complete
begin_test "2.1 approve_plan.sh output contains /tdd after successful approval"
setup
PLAN_FILE="${PLAN_DIR}/sep013-approve-plan.md"
write_plan_with_scope "$PLAN_FILE" "- /project/src/app.py"
state_write planning "1"
state_write planning_started_at "$(date +%s)"
run_hook "$APPROVE" "$(json_posttooluse ExitPlanMode)"
if assert_state_exists "approved" "approval bundle exists"; then
    assert_output_contains "/tdd" && pass
fi
teardown

# 2.2 approve_plan.sh output contains /tdd even when bundle was already complete (idempotent)
begin_test "2.2 approve_plan.sh output contains /tdd when bundle was already complete"
setup
PLAN_FILE="${PLAN_DIR}/sep013-approve-plan2.md"
write_plan_with_scope "$PLAN_FILE" "- /project/src/app.py"
# Pre-write the bundle (simulating validate_plan_quality.sh already ran)
write_approval_bundle "$PLAN_FILE" >/dev/null
run_hook "$APPROVE" "$(json_posttooluse ExitPlanMode)"
assert_output_contains "/tdd" && pass
teardown

# 2.3 The /tdd message should appear in the additionalContext or the allowed output
begin_test "2.3 /tdd instruction appears somewhere in approve_plan.sh output"
setup
PLAN_FILE="${PLAN_DIR}/sep013-approve-plan3.md"
write_plan_with_scope "$PLAN_FILE" "- /project/src/app.py"
state_write planning "1"
state_write planning_started_at "$(date +%s)"
run_hook "$APPROVE" "$(json_posttooluse ExitPlanMode)"
# /tdd must appear somewhere — either in hookSpecificOutput.additionalContext or raw output
if echo "$HOOK_OUTPUT" | grep -q '/tdd' 2>/dev/null; then
    pass
else
    fail "'/tdd' not found anywhere in approve_plan.sh output (got: ${HOOK_OUTPUT:0:300})"
fi
teardown

# ══════════════════════════════════════════════════════════════════
# GROUP 3: check_clear_approval_command.sh injects /tdd in APPROVED phase
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 3: check_clear_approval_command.sh injects /tdd in APPROVED phase ──${NC}\n"

CHECK="${SCRIPTS_DIR}/check_clear_approval_command.sh"

# 3.1 APPROVED phase with no tests_failed → output mentions /tdd
begin_test "3.1 APPROVED phase without tests_failed injects /tdd instruction"
setup
PLAN_FILE="${PLAN_DIR}/sep013-check-plan.md"
write_plan_with_scope "$PLAN_FILE" "- /project/src/app.py"
seed_approval_bundle_from_plan "$PLAN_FILE"
# No tests_failed → should inject /tdd direction
run_hook "$CHECK" "$(json_userpromptsubmit)"
assert_output_contains "/tdd" && pass
teardown

# 3.2 APPROVED phase with tests_failed set (IMPLEMENTING phase) → /tdd not required
begin_test "3.2 IMPLEMENTING phase (tests_failed set) does NOT inject /tdd"
setup
PLAN_FILE="${PLAN_DIR}/sep013-check-plan2.md"
write_plan_with_scope "$PLAN_FILE" "- /project/src/app.py"
seed_approval_bundle_from_plan "$PLAN_FILE"
# tests_failed is set → we are past the TDD red phase, in IMPLEMENTING
state_write tests_failed "2026-03-19T00:00:00Z pytest"
state_write tests_reviewed "1"
run_hook "$CHECK" "$(json_userpromptsubmit)"
# In IMPLEMENTING phase, the model should continue implementing — not be directed to /tdd again
assert_output_not_contains "Invoke /tdd" && pass
teardown

# 3.3 APPROVED phase /tdd injection: the exact phrase "Next: Invoke /tdd" appears
begin_test "3.3 APPROVED phase contains exact phrase 'Next: Invoke /tdd'"
setup
PLAN_FILE="${PLAN_DIR}/sep013-check-plan3.md"
write_plan_with_scope "$PLAN_FILE" "- /project/src/app.py"
seed_approval_bundle_from_plan "$PLAN_FILE"
# No tests_failed → earliest APPROVED state
run_hook "$CHECK" "$(json_userpromptsubmit)"
assert_output_contains "Next: Invoke /tdd" && pass
teardown

# 3.4 APPROVED phase /tdd injection survives when edit_count is non-zero but tests not written
begin_test "3.4 APPROVED phase with edits but no tests_failed still injects /tdd"
setup
PLAN_FILE="${PLAN_DIR}/sep013-check-plan4.md"
write_plan_with_scope "$PLAN_FILE" "- /project/src/app.py"
seed_approval_bundle_from_plan "$PLAN_FILE"
# Simulate some edits happened but tests were never written
state_write edit_count "3"
run_hook "$CHECK" "$(json_userpromptsubmit)"
assert_output_contains "/tdd" && pass
teardown

# 3.5 Non-approved state (idle) does NOT inject /tdd
begin_test "3.5 Idle state (no approved marker) does NOT inject /tdd"
setup
# No approval state at all
run_hook "$CHECK" "$(json_userpromptsubmit)"
assert_output_not_contains "Invoke /tdd" && pass
teardown

# 3.6 Planning state does NOT inject /tdd
begin_test "3.6 PLANNING state does NOT inject /tdd"
setup
state_write planning "1"
state_write planning_started_at "$(date +%s)"
run_hook "$CHECK" "$(json_userpromptsubmit)"
assert_output_not_contains "Invoke /tdd" && pass
teardown

# ══════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}═══ Results ═══${NC}\n"
printf "Total: %d  Passed: %d  Failed: %d\n" "$TOTAL" "$PASSED" "$FAILED"
if [[ $FAILED -gt 0 ]]; then
    printf "${RED}Failures:${NC}%b\n" "$FAILURES"
    exit 1
fi
printf "${GREEN}All tests passed.${NC}\n"
exit 0
