#!/bin/bash
# Test: hook error messages must be unambiguous — single action path, no choices
# These tests FAIL against current code and PASS after the rewrite.

SCRIPTS_DIR="$(dirname "$0")/.."
PASS=0
FAIL=0

assert_no_match() {
    local description="$1"
    local pattern="$2"
    local file="$3"
    if grep -qE "$pattern" "$file"; then
        echo "FAIL: $description"
        echo "  File: $file"
        echo "  Pattern found: $pattern"
        grep -nE "$pattern" "$file" | sed 's/^/  > /'
        FAIL=$((FAIL + 1))
    else
        echo "PASS: $description"
        PASS=$((PASS + 1))
    fi
}

assert_match() {
    local description="$1"
    local pattern="$2"
    local file="$3"
    if grep -qE "$pattern" "$file"; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description"
        echo "  File: $file"
        echo "  Expected pattern not found: $pattern"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Hook Error Message Ambiguity Tests ==="
echo ""

# ── require_plan_approval.sh ──
RPA="$SCRIPTS_DIR/require_plan_approval.sh"

echo "--- require_plan_approval.sh ---"

# No dual-choice "or" patterns in deny messages
assert_no_match \
    "No 'ExitPlanMode or /approve' dual choice" \
    "ExitPlanMode or" \
    "$RPA"

assert_no_match \
    "No 'EnterPlanMode.*or.*approve' dual choice" \
    "EnterPlanMode.*or.*/approve" \
    "$RPA"

assert_no_match \
    "No 'Re-plan with EnterPlanMode, or' dual choice" \
    "Re-plan.*or" \
    "$RPA"

# No conditional "If you" instructions in deny messages
assert_no_match \
    "No 'If you need a different plan' conditional" \
    "If you need a different plan" \
    "$RPA"

assert_no_match \
    "No 'If you already had approval' conditional" \
    "If you already had approval" \
    "$RPA"

# Token mismatch must warn against EnterPlanMode
assert_match \
    "Token mismatch warns against EnterPlanMode" \
    "Do NOT call EnterPlanMode" \
    "$RPA"

# Scope message must prohibit annotations
assert_match \
    "Scope error prohibits '(new)' annotation" \
    "\\(new\\)" \
    "$RPA"

assert_match \
    "Scope error prohibits backticks" \
    "backtick" \
    "$RPA"

# TDD message must specify test file patterns
assert_match \
    "TDD message specifies test file patterns" \
    "test_\*\.py" \
    "$RPA"

echo ""

# ── validate_plan_quality.sh ──
VPQ="$SCRIPTS_DIR/validate_plan_quality.sh"

echo "--- validate_plan_quality.sh ---"

# Scope path error must explicitly prohibit decorations
assert_match \
    "Scope path error says PROHIBITED" \
    "PROHIBITED" \
    "$VPQ"

# No plan file message must specify exact directory
assert_match \
    "No plan file message specifies Write tool" \
    "Write tool" \
    "$VPQ"

# Justification citation error gives pattern example
assert_match \
    "Justification citation error gives 'Because' pattern" \
    "Because.*shows.*plan" \
    "$VPQ"

echo ""

# ── require_investigation_plan.sh ──
RIP="$SCRIPTS_DIR/require_investigation_plan.sh"

echo "--- require_investigation_plan.sh ---"

# Investigation message lists ALL required sections with word counts
assert_match \
    "Investigation message lists ## Hypothesis with word count" \
    "Hypothesis.*15 words" \
    "$RIP"

assert_match \
    "Investigation message lists ## Validation with word count" \
    "Validation.*20 words" \
    "$RIP"

assert_match \
    "Investigation message specifies plan file path" \
    "~/.claude/plans/" \
    "$RIP"

echo ""

# ── approve_plan.sh ──
AP="$SCRIPTS_DIR/approve_plan.sh"

echo "--- approve_plan.sh ---"

assert_no_match \
    "No 'Re-run ExitPlanMode' in fallback error" \
    "Re-run ExitPlanMode" \
    "$AP"

assert_match \
    "Fallback error directs to /approve" \
    "/approve" \
    "$AP"

echo ""

# ── sep_commit_check.sh ──
SCC="$SCRIPTS_DIR/sep_commit_check.sh"

echo "--- sep_commit_check.sh ---"

# Must give explicit ls command to find SEP
assert_match \
    "SEP commit error includes ls command" \
    "ls.*\.sep" \
    "$SCC"

echo ""

# ── Cross-script: no dual-choice patterns anywhere ──
echo "--- Cross-script ambiguity checks ---"

for script in "$RPA" "$VPQ" "$RIP" "$AP" "$SCC"; do
    name=$(basename "$script")
    assert_no_match \
        "[$name] No 'If you (need|already|want)' conditionals" \
        "If you (need|already|want)" \
        "$script"
done

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
