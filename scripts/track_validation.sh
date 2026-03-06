#!/bin/bash
# PostToolUse hook on Bash — detects test/validation commands and manages two-tier validation
# Two-tier: both unit AND E2E tests must pass before dirty clears (SEP-005)
source "$(dirname "$0")/common.sh"
init_hook

COMMAND=$(tool_input command)
[[ -z "$COMMAND" ]] && exit 0

# Match known test runner patterns (unit tests)
UNIT_PATTERN='(^|\s|&&|\|\||;)(npm test|npx (jest|vitest|mocha)|yarn test|pnpm test|bun test|pytest|python -m (pytest|unittest)|go test|cargo test|make (test|check)|rspec|bundle exec (rspec|rake test)|gradlew test|mvn test|dotnet test|phpunit|mix test|dart test|flutter test|deno test|zig test)(\s|$|;|&&|\|\|)'

# E2E/integration test patterns — keywords and flags
E2E_PATTERN='(e2e|end-to-end|integration|functional|cypress|playwright|selenium|puppeteer|--e2e|--integration)'

# Also match explicit calls to record_validation.sh
RECORD_PATTERN='record_validation\.sh'

# Skip record_validation.sh — it handles its own markers
if echo "$COMMAND" | grep -qE "$RECORD_PATTERN"; then
    exit 0
fi

# Determine if this is a unit test, E2E test, or both
IS_UNIT=false
IS_E2E=false

if echo "$COMMAND" | grep -qE "$UNIT_PATTERN"; then
    # It's a test runner command — now check if it's E2E-flavored
    if echo "$COMMAND" | grep -qiE "$E2E_PATTERN"; then
        IS_E2E=true
    else
        IS_UNIT=true
    fi
fi

# Also detect standalone E2E tools that aren't in the unit pattern
if echo "$COMMAND" | grep -qiE "$E2E_PATTERN"; then
    IS_E2E=true
fi

# Nothing matched — exit
if ! $IS_UNIT && ! $IS_E2E; then
    exit 0
fi

# Append to validation log
LOG_FILE=$(state_file validation_log)
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $COMMAND" >> "$LOG_FILE"

# Set tier markers
if $IS_UNIT; then
    state_write validated_unit "$COMMAND"
fi
if $IS_E2E; then
    state_write validated_e2e "$COMMAND"
fi

# Record last validated command
state_write validated "$COMMAND"

# Only clear dirty when BOTH tiers are satisfied
if state_exists validated_unit && state_exists validated_e2e; then
    state_remove dirty
    state_remove validated_unit
    state_remove validated_e2e
    state_remove tests_failed
    allow_with_context "Two-tier validation complete: both unit and E2E passed. Dirty flag cleared." "PostToolUse"
else
    # Report which tier was recorded
    local_msg=""
    if $IS_UNIT; then
        local_msg="Unit test recorded. Still need E2E/integration test to clear dirty."
    else
        local_msg="E2E test recorded. Still need unit test to clear dirty."
    fi
    allow_with_context "$local_msg" "PostToolUse"
fi

exit 0
