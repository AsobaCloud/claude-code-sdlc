#!/bin/bash
# test_resolve_plan_file_for_exit_plan.sh
# Tests for resolve_plan_file_for_exit_plan() pin-on-first-scan behavior.
#
# This test file covers three behaviors required by the fix:
#   1. When SQLite plan_file state key points to a valid, non-done file,
#      resolve_plan_file_for_exit_plan() returns that file without re-scanning.
#   2. When no SQLite plan_file pointer exists but a plan file is found via
#      directory scan, the function pins it by writing state_write plan_file.
#   3. When two plan files exist (one in root plans dir, one in token-scoped
#      dir) and ExitPlanMode is retried, both calls return the same file.
#
# Usage: bash ~/.claude/scripts/tests/test_resolve_plan_file_for_exit_plan.sh

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

# ── Test harness (mirrors test_hooks.sh conventions) ──

setup() {
    TEST_TMPDIR=$(mktemp -d)
    export HOME="${TEST_TMPDIR}/home"
    WORKFLOW_DB="${HOME}/.claude/workflow.db"
    _DB_INITIALIZED=""
    export CONV_ID="test-resolve-001"
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

# Write a minimal plan file (with all required sections)
write_minimal_plan() {
    local plan_file="$1"
    local objective="${2:-Test objective for plan resolution testing}"
    mkdir -p "$(dirname "$plan_file")"
    cat > "$plan_file" <<EOF
## Objective
$objective

## Scope
- /tmp/test-file.sh

## Success Criteria
The plan resolves correctly.

## Justification
Per /Users/shingi/.claude/CLAUDE.md, plan resolution must be deterministic.

## Validation
Local test only.

## Objective Verification
Run bash test.sh and verify output.
EOF
}

# ══════════════════════════════════════════════════════════════════
# GROUP 20: resolve_plan_file_for_exit_plan() pinning behavior
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 20: resolve_plan_file_for_exit_plan() SQLite pointer & pin-on-scan ──${NC}\n"

# 20.1 When SQLite plan_file points to a valid, non-done file and planning is
#      active, resolve_plan_file_for_exit_plan() returns the stored pointer
#      (not a freshly-scanned file from disk).
begin_test "20.1 Returns SQLite plan_file pointer when it exists and file is valid"
setup
# Set up the planning window
state_write planning "1"
state_write planning_started_at "$(date +%s)"

# Create the pinned plan file that is stored in SQLite
PINNED_PLAN="${PLAN_DIR}/pinned-plan.md"
write_minimal_plan "$PINNED_PLAN" "Pinned plan stored in SQLite pointer"
sleep 1

# Also create a NEWER plan file in the root plans dir — without pinning, the
# scanner would pick this up and flip to it.
ROOT_PLAN="${HOME}/.claude/plans/newer-root-plan.md"
write_minimal_plan "$ROOT_PLAN" "Newer root plan that should NOT be returned"

# Pin the older plan via the SQLite plan_file key
state_write plan_file "$PINNED_PLAN"

RESULT=$(resolve_plan_file_for_exit_plan 2>/dev/null)
if [[ "$RESULT" == "$PINNED_PLAN" ]]; then
    pass
else
    fail "Expected pinned plan '$PINNED_PLAN', got '$RESULT'"
fi
teardown

# 20.2 When SQLite plan_file points to a done (completed) plan, the pointer
#      is ignored and the function falls through to scanning.
begin_test "20.2 Ignores SQLite plan_file pointer when pointed file is marked DONE"
setup
state_write planning "1"
state_write planning_started_at "$(date +%s)"

# Create a DONE plan file and store it as the SQLite pointer
DONE_PLAN="${PLAN_DIR}/done-plan.md"
write_minimal_plan "$DONE_PLAN" "Plan that is already completed"
# Prepend the done status marker
TMP_DONE=$(mktemp)
printf '**Status: DONE**\n\n' > "$TMP_DONE"
cat "$DONE_PLAN" >> "$TMP_DONE"
mv "$TMP_DONE" "$DONE_PLAN"
state_write plan_file "$DONE_PLAN"

# Create a valid active plan that the scan should find
ACTIVE_PLAN="${PLAN_DIR}/active-plan.md"
write_minimal_plan "$ACTIVE_PLAN" "Active plan that scanner should find"

RESULT=$(resolve_plan_file_for_exit_plan 2>/dev/null)
if [[ "$RESULT" == "$ACTIVE_PLAN" ]]; then
    pass
else
    fail "Expected active plan '$ACTIVE_PLAN', got '$RESULT'"
fi
teardown

# 20.3 When SQLite plan_file points to a file that no longer exists on disk,
#      the pointer is ignored and the function falls through to scanning.
begin_test "20.3 Ignores SQLite plan_file pointer when file no longer exists"
setup
state_write planning "1"
state_write planning_started_at "$(date +%s)"

# Store a pointer to a non-existent file
state_write plan_file "/nonexistent/path/ghost-plan.md"

# Create a valid plan file via scan
SCANNABLE="${PLAN_DIR}/scannable-plan.md"
write_minimal_plan "$SCANNABLE" "Plan that scanner finds after missing pointer"

RESULT=$(resolve_plan_file_for_exit_plan 2>/dev/null)
if [[ "$RESULT" == "$SCANNABLE" ]]; then
    pass
else
    fail "Expected scanned plan '$SCANNABLE', got '$RESULT'"
fi
teardown

# 20.4 When no SQLite plan_file pointer exists but a plan file is found via
#      scanning, the function writes state_write plan_file to pin it.
begin_test "20.4 Pins found plan file in SQLite via state_write plan_file after scan"
setup
state_write planning "1"
state_write planning_started_at "$(date +%s)"

# No plan_file pointer in SQLite
# Create a plan file that scan can find
SCAN_PLAN="${PLAN_DIR}/scan-and-pin.md"
write_minimal_plan "$SCAN_PLAN" "Plan file found by scan and should be pinned"

# Ensure no plan_file key exists before calling
if state_exists plan_file; then
    state_remove plan_file
fi

RESULT=$(resolve_plan_file_for_exit_plan 2>/dev/null)

# Verify that plan_file was written to SQLite after the scan
PINNED=$(state_read plan_file)
if [[ -n "$PINNED" ]]; then
    pass
else
    fail "Expected plan_file to be pinned in SQLite after scan (result was '$RESULT', pinned was '$PINNED')"
fi
teardown

# 20.5 The pinned value written to SQLite after first scan matches the
#      resolved file path returned by the function.
begin_test "20.5 Pinned SQLite value matches the file path returned by first scan"
setup
state_write planning "1"
state_write planning_started_at "$(date +%s)"

SCAN_PLAN="${PLAN_DIR}/match-check.md"
write_minimal_plan "$SCAN_PLAN" "Plan file; pinned value should match return value"

if state_exists plan_file; then
    state_remove plan_file
fi

RESULT=$(resolve_plan_file_for_exit_plan 2>/dev/null)
PINNED=$(state_read plan_file)

if [[ -n "$RESULT" && "$PINNED" == "$RESULT" ]]; then
    pass
else
    fail "Pinned value '$PINNED' does not match returned value '$RESULT'"
fi
teardown

# 20.6 Two plan files exist: one in the root plans dir
#      (~/.claude/plans/) and one in the token-scoped dir
#      (~/.claude/plans/<token>/). The first call resolves to one of
#      them. The second call (simulating an ExitPlanMode retry) returns
#      the SAME file — no flip-flopping.
begin_test "20.6 Repeated calls return the same file (no flip-flopping)"
setup
state_write planning "1"
PLANNING_TS=$(date +%s)
state_write planning_started_at "$PLANNING_TS"

# Create a plan in root plans dir (shared)
ROOT_PLANS="${HOME}/.claude/plans"
ROOT_PLAN="${ROOT_PLANS}/root-plan.md"
write_minimal_plan "$ROOT_PLAN" "Root directory plan that might flip-flop"
sleep 1

# Create a plan in the token-scoped dir (PLAN_DIR = ~/.claude/plans/<token>)
TOKEN_PLAN="${PLAN_DIR}/token-plan.md"
write_minimal_plan "$TOKEN_PLAN" "Token-scoped plan that might flip-flop"

# Clear any prior plan_file pin to force a fresh scan on first call
if state_exists plan_file; then
    state_remove plan_file
fi

CALL1=$(resolve_plan_file_for_exit_plan 2>/dev/null)
CALL2=$(resolve_plan_file_for_exit_plan 2>/dev/null)

if [[ -n "$CALL1" && "$CALL1" == "$CALL2" ]]; then
    pass
else
    fail "Flip-flop detected: first call='$CALL1', second call='$CALL2'"
fi
teardown

# 20.7 After pin is written (post-scan), a subsequent call that would
#      normally select a DIFFERENT file (e.g., because a new file appeared
#      with a later mtime) still returns the originally-pinned file.
begin_test "20.7 Pin survives even when a newer file appears after first scan"
setup
state_write planning "1"
state_write planning_started_at "$(date +%s)"

# Create and scan the first plan
FIRST_PLAN="${PLAN_DIR}/first-plan.md"
write_minimal_plan "$FIRST_PLAN" "First plan, gets pinned on first scan"

if state_exists plan_file; then
    state_remove plan_file
fi

# First call — scans and pins FIRST_PLAN
CALL1=$(resolve_plan_file_for_exit_plan 2>/dev/null)

# Now create a newer plan file that would win a fresh scan
sleep 1
NEWER_PLAN="${PLAN_DIR}/newer-plan.md"
write_minimal_plan "$NEWER_PLAN" "Newer plan written after pin was set"

# Second call — should still return FIRST_PLAN because it was pinned
CALL2=$(resolve_plan_file_for_exit_plan 2>/dev/null)

if [[ "$CALL1" == "$FIRST_PLAN" && "$CALL2" == "$FIRST_PLAN" ]]; then
    pass
else
    fail "Pin not respected: first='$CALL1' second='$CALL2' (expected both '$FIRST_PLAN')"
fi
teardown

# 20.8 When planning is NOT active (no planning_started_at) and SQLite
#      plan_file is set, resolve_plan_file_for_exit_plan() returns that
#      stored pointer (delegates to resolve_plan_file which honors it).
begin_test "20.8 Returns SQLite pointer when planning window is inactive"
setup
# No planning marker — planning_started_at is absent

POINTER_PLAN="${PLAN_DIR}/pointer-no-planning.md"
write_minimal_plan "$POINTER_PLAN" "Plan stored in pointer, no planning window"
state_write plan_file "$POINTER_PLAN"

RESULT=$(resolve_plan_file_for_exit_plan 2>/dev/null)
if [[ "$RESULT" == "$POINTER_PLAN" ]]; then
    pass
else
    fail "Expected pointer plan '$POINTER_PLAN', got '$RESULT'"
fi
teardown

# 20.9 When planning IS active, the SQLite plan_file pointer takes precedence
#      over a newer file that the scanner would otherwise select.
begin_test "20.9 SQLite pointer wins over newer scanned file during active planning"
setup
state_write planning "1"
state_write planning_started_at "$(date +%s)"

# Create an older plan that we will pin
OLDER_PLAN="${PLAN_DIR}/older-pinned.md"
write_minimal_plan "$OLDER_PLAN" "Older plan explicitly pinned in SQLite"
sleep 1

# Create a newer plan that a scan would pick if no pointer was consulted
NEWER_PLAN="${PLAN_DIR}/newer-unpinned.md"
write_minimal_plan "$NEWER_PLAN" "Newer plan that scan would prefer"

# Pin the OLDER plan
state_write plan_file "$OLDER_PLAN"

RESULT=$(resolve_plan_file_for_exit_plan 2>/dev/null)
if [[ "$RESULT" == "$OLDER_PLAN" ]]; then
    pass
else
    fail "Expected pinned older plan '$OLDER_PLAN', got '$RESULT'"
fi
teardown

# 20.10 When no plan files exist anywhere, resolve_plan_file_for_exit_plan()
#       returns empty / non-zero exit (no spurious pins written).
begin_test "20.10 Returns nothing and writes no pin when no plan files exist"
setup
state_write planning "1"
state_write planning_started_at "$(date +%s)"

# Ensure both directories are empty of .md files
rm -f "${HOME}/.claude/plans"/*.md 2>/dev/null || true
rm -f "${PLAN_DIR}"/*.md 2>/dev/null || true

if state_exists plan_file; then
    state_remove plan_file
fi

RESULT=$(resolve_plan_file_for_exit_plan 2>/dev/null) || true
PINNED=$(state_read plan_file)

if [[ -z "$RESULT" && -z "$PINNED" ]]; then
    pass
else
    fail "Expected empty result and no pin (result='$RESULT', pinned='$PINNED')"
fi
teardown

# ══════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════
printf "\n"
printf "Results: %d passed, %d failed, %d total\n" "$PASSED" "$FAILED" "$TOTAL"
if [[ "$FAILED" -gt 0 ]]; then
    printf "\nFailed tests:\n"
    printf "%b" "$FAILURES"
    exit 1
else
    printf "All tests passed.\n"
    exit 0
fi
