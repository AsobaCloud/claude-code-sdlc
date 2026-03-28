#!/bin/bash
# Test script to verify clear_all_state replacement

# Test 1: Check that clear_all_state is not present in the specified files
test_clear_all_state_removed() {
    local files=(
        "/Users/shingi/.claude/scripts/common.sh"
        "/Users/shingi/.claude/scripts/clear_plan_on_new_task.sh"
        "/Users/shingi/.claude/scripts/clear_approval.sh"
        "/Users/shingi/.claude/scripts/accept_outcome.sh"
        "/Users/shingi/.claude/scripts/reject_outcome.sh"
        "/Users/shingi/.claude/scripts/check_clear_approval_command.sh"
    )
    
    local failed=0
    for file in "${files[@]}"; do
        if grep -q "clear_all_state" "$file"; then
            echo "FAIL: clear_all_state found in $file"
            failed=$((failed + 1))
        else
            echo "PASS: clear_all_state not found in $file"
        fi
    done
    
    if [[ $failed -eq 0 ]]; then
        echo "All tests passed: clear_all_state removed from all files"
        return 0
    else
        echo "Tests failed: $failed files still contain clear_all_state"
        return 1
    fi
}

# Test 2: Check that clear_workflow_keys and clear_plan_context_keys are used appropriately
test_selective_clear_functions_used() {
    # Files that should use both clear_workflow_keys and clear_plan_context_keys
    local selective_clear_files=(
        "/Users/shingi/.claude/scripts/clear_plan_on_new_task.sh"
        "/Users/shingi/.claude/scripts/clear_approval.sh"
        "/Users/shingi/.claude/scripts/accept_outcome.sh"
        "/Users/shingi/.claude/scripts/reject_outcome.sh"
    )
    
    local failed=0
    for file in "${selective_clear_files[@]}"; do
        if ! grep -q "clear_workflow_keys" "$file"; then
            echo "FAIL: clear_workflow_keys not found in $file"
            failed=$((failed + 1))
        fi
        
        if ! grep -q "clear_plan_context_keys" "$file"; then
            echo "FAIL: clear_plan_context_keys not found in $file"
            failed=$((failed + 1))
        fi
        
        if grep -q "clear_workflow_keys" "$file" && grep -q "clear_plan_context_keys" "$file"; then
            echo "PASS: Both selective clear functions found in $file"
        fi
    done
    
    if [[ $failed -eq 0 ]]; then
        echo "All tests passed: selective clear functions used appropriately"
        return 0
    else
        echo "Tests failed: $failed issues with selective clear function usage"
        return 1
    fi
}

# Run tests
echo "Running tests for clear_all_state replacement..."
echo ""

test_clear_all_state_removed
echo ""
test_selective_clear_functions_used