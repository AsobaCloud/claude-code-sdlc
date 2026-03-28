#!/bin/bash
# test_sep_verify_skill.sh — Tests for the /verify skill and qa-verifier agent
#
# Verifies six behaviors that do not yet exist:
#   1. qa-verifier.md agent exists at ~/.claude/agents/qa-verifier.md
#   2. /verify command file exists at ~/.claude/commands/verify.md
#   3. /verify skill file exists at ~/.claude/skills/verify/SKILL.md
#   4. qa-verifier.md enforces epistemic isolation (objective+criteria only, no plan details)
#   5. SKILL.md for /verify invokes qa-verifier with only objective+criteria
#   6. SKILL.md for /verify calls record_validation.sh and clear_approval.sh on all-pass
#   7. /tdd SKILL.md hands off to /verify rather than running verification directly
#   8. ARCHITECTURE.md documents VERIFYING phase, qa-verifier agent, and verifying state marker
#   9. check_clear_approval_command.sh (workflow state) injects VERIFYING phase after two-tier validation
#  10. /verify SKILL.md specifies at least one verification step per success criterion
#
# Usage: bash ~/.claude/scripts/tests/test_sep_verify_skill.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS_DIR="${HOME}/.claude/agents"
COMMANDS_DIR="${HOME}/.claude/commands"
SKILLS_DIR="${HOME}/.claude/skills"
ARCH_FILE="${HOME}/.claude/docs/ARCHITECTURE.md"

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

# ── Test harness (matches test_sep013_tdd_skill.sh) ──

setup() {
    TEST_TMPDIR=$(mktemp -d)
    export HOME="${TEST_TMPDIR}/home"
    WORKFLOW_DB="${HOME}/.claude/workflow.db"
    _DB_INITIALIZED=""
    export CONV_ID="test-session-sep-verify"
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

assert_file_exists() {
    local path="$1"
    local label="${2:-file '$path' exists}"
    if [[ ! -f "$path" ]]; then
        fail "Expected file to exist: $path"
        return 1
    fi
    return 0
}

assert_file_contains() {
    local path="$1"
    local pattern="$2"
    local label="${3:-file '$path' contains '$pattern'}"
    if ! grep -q "$pattern" "$path" 2>/dev/null; then
        fail "File '$path' does not contain pattern: $pattern"
        return 1
    fi
    return 0
}

assert_file_not_contains() {
    local path="$1"
    local pattern="$2"
    if grep -q "$pattern" "$path" 2>/dev/null; then
        fail "File '$path' should NOT contain: $pattern"
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

json_userpromptsubmit() {
    jq -n '{"session_id":"test-session-sep-verify","tool_name":"UserPromptSubmit","tool_input":{}}'
}

json_posttooluse() {
    local tool="$1"
    jq -n --arg tool "$tool" \
        '{"session_id":"test-session-sep-verify","tool_name":$tool,"tool_input":{}}'
}

# Write a standard plan with two success criteria (used for multiple tests)
write_verify_test_plan() {
    local plan_file="$1"
    mkdir -p "$(dirname "$plan_file")"
    cat > "$plan_file" <<'EOF'
## Objective
Add a QA verifier agent and /verify skill that generates criteria-driven acceptance checks for the hook system. Implements SEP-018.

## Scope
- /Users/shingi/.claude/agents/qa-verifier.md
- /Users/shingi/.claude/skills/verify/SKILL.md
- /Users/shingi/.claude/commands/verify.md

## Success Criteria
The qa-verifier agent receives only objective and success criteria (epistemic isolation).
The /verify skill calls record_validation.sh and clear_approval.sh on all-pass.

## Justification
ARCHITECTURE.md section 2 defines the VERIFIED phase following two-tier validation. The current system requires pre-written commands, which is a checkbox — not real QA.

## Validation
Sources: ARCHITECTURE.md, check_clear_approval_command.sh, record_validation.sh.
Evidence: No VERIFYING phase exists in check_clear_approval_command.sh workflow state.
Verified: qa-verifier.md does not yet exist.
Known gaps: orchestrator integration test is manual.

## Objective Verification
bash ~/.claude/scripts/tests/test_sep_verify_skill.sh
EOF
}

seed_approval_from_plan() {
    local plan_file="$1"
    write_approval_bundle "$plan_file" >/dev/null
}

# ══════════════════════════════════════════════════════════════════
# GROUP 1: Required files exist
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 1: Required files exist ──${NC}\n"

# 1.1 qa-verifier.md agent file must exist
begin_test "1.1 qa-verifier.md exists at ~/.claude/agents/qa-verifier.md"
if assert_file_exists "${AGENTS_DIR}/qa-verifier.md"; then
    pass
fi

# 1.2 /verify command file must exist
begin_test "1.2 verify.md exists at ~/.claude/commands/verify.md"
if assert_file_exists "${COMMANDS_DIR}/verify.md"; then
    pass
fi

# 1.3 /verify skill file must exist
begin_test "1.3 SKILL.md exists at ~/.claude/skills/verify/SKILL.md"
if assert_file_exists "${SKILLS_DIR}/verify/SKILL.md"; then
    pass
fi

# ══════════════════════════════════════════════════════════════════
# GROUP 2: qa-verifier.md agent enforces epistemic isolation
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 2: qa-verifier.md enforces epistemic isolation ──${NC}\n"

# 2.1 qa-verifier.md must declare it receives only objective and success criteria
begin_test "2.1 qa-verifier.md states it receives only objective and success criteria"
QA_AGENT="${AGENTS_DIR}/qa-verifier.md"
if [[ -f "$QA_AGENT" ]]; then
    if assert_file_contains "$QA_AGENT" "objective" && \
       assert_file_contains "$QA_AGENT" "criteria"; then
        pass
    fi
else
    fail "qa-verifier.md not found at ${QA_AGENT}"
fi

# 2.2 qa-verifier.md must explicitly state it does NOT receive plan details or implementation
begin_test "2.2 qa-verifier.md explicitly excludes plan details / implementation from its input"
QA_AGENT="${AGENTS_DIR}/qa-verifier.md"
if [[ -f "$QA_AGENT" ]]; then
    # It must prohibit or explicitly exclude plan implementation details
    if assert_file_contains "$QA_AGENT" "plan" && \
       assert_file_contains "$QA_AGENT" "NOT"; then
        pass
    fi
else
    fail "qa-verifier.md not found at ${QA_AGENT}"
fi

# 2.3 qa-verifier.md must require generating at least one verification step per criterion
begin_test "2.3 qa-verifier.md specifies at least one verification step per success criterion"
QA_AGENT="${AGENTS_DIR}/qa-verifier.md"
if [[ -f "$QA_AGENT" ]]; then
    # Must mention generating steps from criteria
    if grep -q "criterion\|criteria" "$QA_AGENT" 2>/dev/null; then
        if grep -q "step\|verif" "$QA_AGENT" 2>/dev/null; then
            pass
        else
            fail "qa-verifier.md does not mention verification steps"
        fi
    else
        fail "qa-verifier.md does not mention criteria"
    fi
else
    fail "qa-verifier.md not found at ${QA_AGENT}"
fi

# 2.4 qa-verifier.md must specify structured pass/fail output
begin_test "2.4 qa-verifier.md specifies structured pass/fail output format"
QA_AGENT="${AGENTS_DIR}/qa-verifier.md"
if [[ -f "$QA_AGENT" ]]; then
    if assert_file_contains "$QA_AGENT" "pass" && \
       assert_file_contains "$QA_AGENT" "fail"; then
        pass
    fi
else
    fail "qa-verifier.md not found at ${QA_AGENT}"
fi

# 2.5 qa-verifier.md frontmatter must reference qa-verifier as agent name
begin_test "2.5 qa-verifier.md frontmatter declares name: qa-verifier"
QA_AGENT="${AGENTS_DIR}/qa-verifier.md"
if [[ -f "$QA_AGENT" ]]; then
    if assert_file_contains "$QA_AGENT" "qa-verifier"; then
        pass
    fi
else
    fail "qa-verifier.md not found at ${QA_AGENT}"
fi

# ══════════════════════════════════════════════════════════════════
# GROUP 3: /verify SKILL.md orchestrator behavior
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 3: /verify SKILL.md orchestrator behavior ──${NC}\n"

VERIFY_SKILL="${SKILLS_DIR}/verify/SKILL.md"

# 3.1 /verify SKILL.md must specify launching qa-verifier agent
begin_test "3.1 verify SKILL.md launches the qa-verifier agent"
if [[ -f "$VERIFY_SKILL" ]]; then
    if assert_file_contains "$VERIFY_SKILL" "qa-verifier"; then
        pass
    fi
else
    fail "SKILL.md not found at ${VERIFY_SKILL}"
fi

# 3.2 /verify SKILL.md must specify passing only objective and criteria to the agent
begin_test "3.2 verify SKILL.md passes only objective and criteria to qa-verifier (epistemic isolation)"
if [[ -f "$VERIFY_SKILL" ]]; then
    if assert_file_contains "$VERIFY_SKILL" "objective" && \
       assert_file_contains "$VERIFY_SKILL" "criteria"; then
        pass
    fi
else
    fail "SKILL.md not found at ${VERIFY_SKILL}"
fi

# 3.3 /verify SKILL.md must NOT pass plan details to the agent
begin_test "3.3 verify SKILL.md does not pass implementation or plan details to agent"
if [[ -f "$VERIFY_SKILL" ]]; then
    # It should mention NOT passing implementation details
    if assert_file_contains "$VERIFY_SKILL" "NOT"; then
        pass
    fi
else
    fail "SKILL.md not found at ${VERIFY_SKILL}"
fi

# 3.4 /verify SKILL.md must specify calling record_validation.sh on all-pass
begin_test "3.4 verify SKILL.md calls record_validation.sh on all-pass"
if [[ -f "$VERIFY_SKILL" ]]; then
    if assert_file_contains "$VERIFY_SKILL" "record_validation.sh"; then
        pass
    fi
else
    fail "SKILL.md not found at ${VERIFY_SKILL}"
fi

# 3.5 /verify SKILL.md must specify calling clear_approval.sh after recording
begin_test "3.5 verify SKILL.md calls clear_approval.sh after recording verification"
if [[ -f "$VERIFY_SKILL" ]]; then
    if assert_file_contains "$VERIFY_SKILL" "clear_approval.sh"; then
        pass
    fi
else
    fail "SKILL.md not found at ${VERIFY_SKILL}"
fi

# 3.6 /verify SKILL.md must specify what to do if any step fails (not silently passing)
begin_test "3.6 verify SKILL.md specifies failure handling when any step fails"
if [[ -f "$VERIFY_SKILL" ]]; then
    # Must mention reporting failures or not calling clear_approval.sh on failure
    if grep -q "fail\|FAIL\|reject\|BLOCKED\|stop" "$VERIFY_SKILL" 2>/dev/null; then
        pass
    else
        fail "SKILL.md does not mention failure handling"
    fi
else
    fail "SKILL.md not found at ${VERIFY_SKILL}"
fi

# 3.7 /verify command file must mention qa-verifier or verify skill
begin_test "3.7 verify command file references qa-verifier or the verify skill"
VERIFY_CMD="${COMMANDS_DIR}/verify.md"
if [[ -f "$VERIFY_CMD" ]]; then
    if grep -q "qa-verifier\|verify\|SKILL" "$VERIFY_CMD" 2>/dev/null; then
        pass
    else
        fail "verify.md command file does not reference qa-verifier or SKILL"
    fi
else
    fail "verify.md not found at ${VERIFY_CMD}"
fi

# ══════════════════════════════════════════════════════════════════
# GROUP 4: /tdd SKILL.md hands off to /verify
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 4: /tdd SKILL.md hands off to /verify ──${NC}\n"

TDD_SKILL="${SKILLS_DIR}/tdd/SKILL.md"

# 4.1 /tdd SKILL.md must reference /verify for the post-implementation verification step
begin_test "4.1 /tdd SKILL.md references /verify for post-implementation verification"
if [[ -f "$TDD_SKILL" ]]; then
    if assert_file_contains "$TDD_SKILL" "/verify"; then
        pass
    fi
else
    fail "TDD SKILL.md not found at ${TDD_SKILL}"
fi

# 4.2 /tdd SKILL.md must NOT instruct running an objective verification command directly
begin_test "4.2 /tdd SKILL.md does not instruct running the approved Objective Verification command directly"
if [[ -f "$TDD_SKILL" ]]; then
    # The old text "Run the approved Objective Verification command from the plan" must be gone
    if grep -q "Run the approved Objective Verification command" "$TDD_SKILL" 2>/dev/null; then
        fail "/tdd SKILL.md still contains 'Run the approved Objective Verification command' — should hand off to /verify instead"
    else
        pass
    fi
else
    fail "TDD SKILL.md not found at ${TDD_SKILL}"
fi

# 4.3 /tdd command file must also reference /verify
begin_test "4.3 /tdd command file references /verify for verification phase"
TDD_CMD="${COMMANDS_DIR}/tdd.md"
if [[ -f "$TDD_CMD" ]]; then
    if assert_file_contains "$TDD_CMD" "/verify"; then
        pass
    fi
else
    fail "TDD command file not found at ${TDD_CMD}"
fi

# 4.4 /tdd command file must NOT instruct running the approved Objective Verification command directly
begin_test "4.4 /tdd command file does not run Objective Verification command directly"
TDD_CMD="${COMMANDS_DIR}/tdd.md"
if [[ -f "$TDD_CMD" ]]; then
    if grep -q "Run the approved Objective Verification command" "$TDD_CMD" 2>/dev/null; then
        fail "/tdd command still contains 'Run the approved Objective Verification command' — should hand off to /verify"
    else
        pass
    fi
else
    fail "TDD command file not found at ${TDD_CMD}"
fi

# ══════════════════════════════════════════════════════════════════
# GROUP 5: ARCHITECTURE.md documents VERIFYING phase and qa-verifier
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 5: ARCHITECTURE.md documents new additions ──${NC}\n"

# 5.1 ARCHITECTURE.md must contain VERIFYING phase in the state machine
begin_test "5.1 ARCHITECTURE.md state machine includes VERIFYING phase"
if [[ -f "$ARCH_FILE" ]]; then
    if assert_file_contains "$ARCH_FILE" "VERIFYING"; then
        pass
    fi
else
    fail "ARCHITECTURE.md not found at ${ARCH_FILE}"
fi

# 5.2 ARCHITECTURE.md must document qa-verifier agent
begin_test "5.2 ARCHITECTURE.md documents the qa-verifier agent"
if [[ -f "$ARCH_FILE" ]]; then
    if assert_file_contains "$ARCH_FILE" "qa-verifier"; then
        pass
    fi
else
    fail "ARCHITECTURE.md not found at ${ARCH_FILE}"
fi

# 5.3 ARCHITECTURE.md must document the /verify skill
begin_test "5.3 ARCHITECTURE.md documents the /verify skill or command"
if [[ -f "$ARCH_FILE" ]]; then
    if grep -q "/verify\|verify skill\|verify command" "$ARCH_FILE" 2>/dev/null; then
        pass
    else
        fail "ARCHITECTURE.md does not mention /verify"
    fi
else
    fail "ARCHITECTURE.md not found at ${ARCH_FILE}"
fi

# 5.4 ARCHITECTURE.md must document the validation_complete state marker
begin_test "5.4 ARCHITECTURE.md documents the validation_complete state marker"
if [[ -f "$ARCH_FILE" ]]; then
    if assert_file_contains "$ARCH_FILE" "validation_complete"; then
        pass
    fi
else
    fail "ARCHITECTURE.md not found at ${ARCH_FILE}"
fi

# 5.5 ARCHITECTURE.md state machine must still include the original phases (regression)
begin_test "5.5 ARCHITECTURE.md still includes IMPLEMENTING and VERIFIED phases (regression)"
if [[ -f "$ARCH_FILE" ]]; then
    if assert_file_contains "$ARCH_FILE" "IMPLEMENTING" && \
       assert_file_contains "$ARCH_FILE" "VERIFIED"; then
        pass
    fi
else
    fail "ARCHITECTURE.md not found at ${ARCH_FILE}"
fi

# ══════════════════════════════════════════════════════════════════
# GROUP 6: track_validation.sh sets validation_complete marker
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 6: track_validation.sh sets validation_complete after two-tier completion ──${NC}\n"

TRACK="${SCRIPTS_DIR}/track_validation.sh"

json_bash_posttooluse() {
    local cmd="$1"
    jq -n --arg cmd "$cmd" \
        '{"session_id":"test-session-sep-verify","tool_name":"Bash","tool_input":{"command":$cmd}}'
}

# 6.1 After unit + E2E both pass, validation_complete marker is set
begin_test "6.1 track_validation.sh sets validation_complete after unit+E2E both pass"
setup
PLAN_FILE="${PLAN_DIR}/sep-verify-track-plan.md"
write_verify_test_plan "$PLAN_FILE"
seed_approval_from_plan "$PLAN_FILE"
state_write dirty "2026-03-21T00:00:00Z /some/file.sh"
# Run unit test first
run_hook "$TRACK" "$(json_bash_posttooluse "pytest")"
assert_state_not_exists "validation_complete" "not yet — only unit done"
# Run E2E test second
run_hook "$TRACK" "$(json_bash_posttooluse "pytest --integration")"
if assert_state_exists "validation_complete" "validation_complete must be set after both tiers pass"; then
    pass
fi
teardown

# 6.2 validation_complete is NOT set after only unit test passes
begin_test "6.2 validation_complete NOT set after only unit test (two-tier not yet satisfied)"
setup
PLAN_FILE="${PLAN_DIR}/sep-verify-track-plan2.md"
write_verify_test_plan "$PLAN_FILE"
seed_approval_from_plan "$PLAN_FILE"
state_write dirty "2026-03-21T00:00:00Z /some/file.sh"
run_hook "$TRACK" "$(json_bash_posttooluse "pytest")"
if assert_state_not_exists "validation_complete" "only unit done — E2E still needed"; then
    pass
fi
teardown

# 6.3 validation_complete is NOT set after only E2E test passes
begin_test "6.3 validation_complete NOT set after only E2E test (unit tier still needed)"
setup
PLAN_FILE="${PLAN_DIR}/sep-verify-track-plan3.md"
write_verify_test_plan "$PLAN_FILE"
seed_approval_from_plan "$PLAN_FILE"
state_write dirty "2026-03-21T00:00:00Z /some/file.sh"
run_hook "$TRACK" "$(json_bash_posttooluse "npx playwright test")"
if assert_state_not_exists "validation_complete" "only E2E done — unit tier still needed"; then
    pass
fi
teardown

# ══════════════════════════════════════════════════════════════════
# GROUP 7: check_clear_approval_command.sh shows VERIFYING phase
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 7: Workflow state shows VERIFYING phase after two-tier validation ──${NC}\n"

CHECK="${SCRIPTS_DIR}/check_clear_approval_command.sh"

# 7.1 After two-tier validation passes (validation_complete set, dirty cleared)
#     but before objective_verified, the workflow state phase should be VERIFYING
begin_test "7.1 Workflow state shows VERIFYING phase when validation_complete set but objective not yet verified"
setup
PLAN_FILE="${PLAN_DIR}/sep-verify-check-plan.md"
write_verify_test_plan "$PLAN_FILE"
seed_approval_from_plan "$PLAN_FILE"
state_write tests_failed "2026-03-21T00:00:00Z pytest"
state_write tests_reviewed "1"
# two-tier complete: dirty cleared, validation_complete set
state_write validation_complete "2026-03-21T12:00:00Z"
# objective_verified is NOT set
run_hook "$CHECK" "$(json_userpromptsubmit)"
if assert_output_contains "VERIFYING"; then
    pass
fi
teardown

# 7.2 VERIFYING phase must instruct invoking /verify
# Checks for the specific "Next: Invoke /verify" directive — not just any /verify appearance
begin_test "7.2 VERIFYING phase instructs invoking /verify"
setup
PLAN_FILE="${PLAN_DIR}/sep-verify-check-plan2.md"
write_verify_test_plan "$PLAN_FILE"
seed_approval_from_plan "$PLAN_FILE"
state_write tests_failed "2026-03-21T00:00:00Z pytest"
state_write tests_reviewed "1"
state_write validation_complete "2026-03-21T12:00:00Z"
run_hook "$CHECK" "$(json_userpromptsubmit)"
if assert_output_contains "Invoke /verify"; then
    pass
fi
teardown

# 7.3 IMPLEMENTING phase (dirty set, no validation_complete) does NOT show VERIFYING
begin_test "7.3 IMPLEMENTING phase (dirty flag set, no validation_complete) does NOT show VERIFYING"
setup
PLAN_FILE="${PLAN_DIR}/sep-verify-check-plan3.md"
write_verify_test_plan "$PLAN_FILE"
seed_approval_from_plan "$PLAN_FILE"
state_write tests_failed "2026-03-21T00:00:00Z pytest"
state_write tests_reviewed "1"
state_write dirty "2026-03-21T00:00:00Z /some/file.sh"
# no validation_complete
run_hook "$CHECK" "$(json_userpromptsubmit)"
if assert_output_not_contains "VERIFYING"; then
    pass
fi
teardown

# 7.4 APPROVED phase (no tests_failed) does NOT show VERIFYING
begin_test "7.4 APPROVED phase (no tests_failed, no validation_complete) does NOT show VERIFYING"
setup
PLAN_FILE="${PLAN_DIR}/sep-verify-check-plan4.md"
write_verify_test_plan "$PLAN_FILE"
seed_approval_from_plan "$PLAN_FILE"
# No tests_failed, no validation tiers, no validation_complete
run_hook "$CHECK" "$(json_userpromptsubmit)"
if assert_output_not_contains "VERIFYING"; then
    pass
fi
teardown

# 7.5 After objective_verified is set, phase transitions away from VERIFYING
begin_test "7.5 After objective_verified is set, workflow phase is no longer VERIFYING"
setup
PLAN_FILE="${PLAN_DIR}/sep-verify-check-plan5.md"
write_verify_test_plan "$PLAN_FILE"
seed_approval_from_plan "$PLAN_FILE"
state_write tests_failed "2026-03-21T00:00:00Z pytest"
state_write tests_reviewed "1"
state_write validation_complete "2026-03-21T12:00:00Z"
# Now simulate objective has been verified
PLAN_HASH=$(state_read plan_hash)
EDIT_CT=$(state_read edit_count)
[[ "$EDIT_CT" =~ ^[0-9]+$ ]] || EDIT_CT=0
state_write objective_verified "2026-03-21T12:00:00Z"
state_write objective_verified_hash "$PLAN_HASH"
state_write objective_verified_edit_count "$EDIT_CT"
state_write objective_verified_evidence "bash ~/.claude/scripts/tests/test_sep_verify_skill.sh"
run_hook "$CHECK" "$(json_userpromptsubmit)"
if assert_output_not_contains "VERIFYING"; then
    pass
fi
teardown

# 7.6 VERIFYING phase uses "Next: Invoke /verify" as the direction message
begin_test "7.6 VERIFYING phase contains 'Next: Invoke /verify' direction"
setup
PLAN_FILE="${PLAN_DIR}/sep-verify-check-plan6.md"
write_verify_test_plan "$PLAN_FILE"
seed_approval_from_plan "$PLAN_FILE"
state_write tests_failed "2026-03-21T00:00:00Z pytest"
state_write tests_reviewed "1"
state_write validation_complete "2026-03-21T12:00:00Z"
run_hook "$CHECK" "$(json_userpromptsubmit)"
if assert_output_contains "Next: Invoke /verify"; then
    pass
fi
teardown

# ══════════════════════════════════════════════════════════════════
# GROUP 8: validation_complete in clear_workflow_keys (common.sh)
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 8: common.sh clears validation_complete in clear_workflow_keys ──${NC}\n"

# 8.1 After clear_workflow_keys(), validation_complete is removed
begin_test "8.1 clear_workflow_keys removes validation_complete state key"
setup
state_write validation_complete "2026-03-21T12:00:00Z"
assert_state_exists "validation_complete" "precondition: key is set"
clear_workflow_keys
if assert_state_not_exists "validation_complete" "validation_complete must be cleared"; then
    pass
fi
teardown

# 8.2 common.sh clear_workflow_keys still clears all original keys (regression)
begin_test "8.2 clear_workflow_keys still clears approved, dirty, tests_failed (regression)"
setup
state_write approved "1"
state_write dirty "2026-03-21T00:00:00Z /some/file"
state_write tests_failed "2026-03-21T00:00:00Z pytest"
state_write validation_complete "2026-03-21T12:00:00Z"
clear_workflow_keys
all_ok=true
state_exists "approved" && all_ok=false
state_exists "dirty" && all_ok=false
state_exists "tests_failed" && all_ok=false
if [[ "$all_ok" == "true" ]]; then
    pass
else
    fail "Original workflow keys were not cleared by clear_workflow_keys"
fi
teardown

# ══════════════════════════════════════════════════════════════════
# GROUP 9: record_validation.sh + clear_approval.sh integration
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 9: record_validation.sh succeeds when command appears in validation log ──${NC}\n"

RECORD="${SCRIPTS_DIR}/record_validation.sh"
CLEAR="${SCRIPTS_DIR}/clear_approval.sh"

# 9.1 record_validation.sh --command succeeds when command is in validation_log and matches OV section
begin_test "9.1 record_validation.sh --command succeeds when command appears in validation_log"
setup
PLAN_FILE="${PLAN_DIR}/sep-verify-record-plan.md"
write_verify_test_plan "$PLAN_FILE"
seed_approval_from_plan "$PLAN_FILE"
# The verify skill will have run a command; add it to validation_log first
VERIFY_CMD="bash ~/.claude/scripts/tests/test_sep_verify_skill.sh"
state_append validation_log "$(date -u +%Y-%m-%dT%H:%M:%SZ) ${VERIFY_CMD}"
run_script "$RECORD" --command "$VERIFY_CMD"
if assert_exit_code 0; then
    pass
fi
teardown

# 9.2 After record_validation.sh --command succeeds, clear_approval.sh also succeeds
begin_test "9.2 clear_approval.sh succeeds after objective verification recorded"
setup
PLAN_FILE="${PLAN_DIR}/sep-verify-clear-plan.md"
write_verify_test_plan "$PLAN_FILE"
seed_approval_from_plan "$PLAN_FILE"
# Simulate complete workflow: dirty was cleared (not set), objective verified
PLAN_HASH=$(state_read plan_hash)
state_write objective_verified "2026-03-21T12:00:00Z"
state_write objective_verified_hash "$PLAN_HASH"
state_write objective_verified_edit_count "0"
state_write objective_verified_evidence "bash ~/.claude/scripts/tests/test_sep_verify_skill.sh"
state_append validation_log "$(date -u +%Y-%m-%dT%H:%M:%SZ) [OBJECTIVE VERIFIED] bash ~/.claude/scripts/tests/test_sep_verify_skill.sh"
run_script "$CLEAR"
if assert_exit_code 0; then
    pass
fi
teardown

# 9.3 clear_approval.sh is blocked when objective verification has NOT been recorded
# Uses a plan with a .sh file in scope so objective_verification_required=1
begin_test "9.3 clear_approval.sh is blocked when objective verification not recorded"
setup
PLAN_FILE="${PLAN_DIR}/sep-verify-clear-blocked-plan.md"
mkdir -p "$(dirname "$PLAN_FILE")"
cat > "$PLAN_FILE" <<'PLANEOF'
## Objective
Test plan with a shell script in scope so objective verification is required. Implements SEP-018.

## Scope
- /Users/shingi/.claude/scripts/check_clear_approval_command.sh

## Success Criteria
clear_approval.sh blocks when objective verification not yet recorded.

## Justification
Tests that the gate works before recording. Required by ARCHITECTURE.md lifecycle contract.

## Validation
Sources: clear_approval.sh, common.sh. Evidence: objective_verification_required is 1 for .sh scope.
Verified: gate exists in clear_approval.sh. Known gaps: none.

## Objective Verification
bash /Users/shingi/.claude/scripts/tests/test_sep_verify_skill.sh
PLANEOF
seed_approval_from_plan "$PLAN_FILE"
# objective_verification_required is now 1 — but we have NOT recorded objective_verified
run_script "$CLEAR"
if assert_exit_code 1; then
    assert_output_contains "BLOCKED" && pass
fi
teardown

# ══════════════════════════════════════════════════════════════════
# GROUP 10: Epistemic isolation invariant for qa-verifier prompt
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 10: Epistemic isolation — qa-verifier agent file invariants ──${NC}\n"

# 10.1 qa-verifier.md must include a MUST NOT section prohibiting reading plan files
begin_test "10.1 qa-verifier.md has MUST NOT section prohibiting access to plan files"
QA_AGENT="${AGENTS_DIR}/qa-verifier.md"
if [[ -f "$QA_AGENT" ]]; then
    if grep -q "MUST NOT\|must not" "$QA_AGENT" 2>/dev/null && \
       grep -q "plan" "$QA_AGENT" 2>/dev/null; then
        pass
    else
        fail "qa-verifier.md missing MUST NOT prohibition for plan file access"
    fi
else
    fail "qa-verifier.md not found at ${QA_AGENT}"
fi

# 10.2 qa-verifier.md must not instruct reading plan directories
begin_test "10.2 qa-verifier.md does not instruct reading .claude/plans/ directories"
QA_AGENT="${AGENTS_DIR}/qa-verifier.md"
if [[ -f "$QA_AGENT" ]]; then
    if grep -q "\.claude/plans/" "$QA_AGENT" 2>/dev/null; then
        fail "qa-verifier.md instructs reading .claude/plans/ which violates epistemic isolation"
    else
        pass
    fi
else
    fail "qa-verifier.md not found at ${QA_AGENT}"
fi

# 10.3 verify SKILL.md prompt template does not pass Plan/Justification sections to agent
begin_test "10.3 verify SKILL.md prompt template excludes Plan/Justification/Validation sections from agent input"
VERIFY_SKILL="${SKILLS_DIR}/verify/SKILL.md"
if [[ -f "$VERIFY_SKILL" ]]; then
    # If Justification is mentioned, it must be in a "do NOT pass" context
    if grep -q "Justification" "$VERIFY_SKILL" 2>/dev/null; then
        if grep -B2 -A2 "Justification" "$VERIFY_SKILL" 2>/dev/null | grep -qi "NOT\|not\|exclude\|omit\|Do NOT" 2>/dev/null; then
            pass
        else
            fail "verify SKILL.md mentions Justification section without prohibiting passing it to the agent"
        fi
    else
        # Not mentioned at all — prohibition is implicit via only-objective-and-criteria rule
        pass
    fi
else
    fail "SKILL.md not found at ${VERIFY_SKILL}"
fi

# ══════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}═══ Results ═══${NC}\n"
printf "Total: %d  Passed: %d  Failed: %d\n" "$TOTAL" "$PASSED" "$FAILED"
if [[ $FAILED -gt 0 ]]; then
    printf "${RED}Failures:${NC}\n%b\n" "$FAILURES"
    exit 1
fi
printf "${GREEN}All tests passed.${NC}\n"
exit 0
