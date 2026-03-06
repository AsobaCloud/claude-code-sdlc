#!/bin/bash
# PostToolUseFailure hook on Bash — detects failing test runs (red phase of TDD)
# When a test runner command fails (non-zero exit), sets tests_failed marker.
# This is the "red" signal in red-green TDD enforcement.
source "$(dirname "$0")/common.sh"
init_hook

COMMAND=$(tool_input command)
[[ -z "$COMMAND" ]] && exit 0

# Same test runner patterns as track_validation.sh
UNIT_PATTERN='(^|\s|&&|\|\||;)(npm test|npx (jest|vitest|mocha)|yarn test|pnpm test|bun test|pytest|python -m (pytest|unittest)|go test|cargo test|make (test|check)|rspec|bundle exec (rspec|rake test)|gradlew test|mvn test|dotnet test|phpunit|mix test|dart test|flutter test|deno test|zig test)(\s|$|;|&&|\|\|)'
E2E_PATTERN='(e2e|end-to-end|integration|functional|cypress|playwright|selenium|puppeteer|--e2e|--integration)'

IS_TEST=false
if echo "$COMMAND" | grep -qE "$UNIT_PATTERN"; then
    IS_TEST=true
fi
if echo "$COMMAND" | grep -qiE "$E2E_PATTERN"; then
    IS_TEST=true
fi

if $IS_TEST; then
    state_write tests_failed "$(date -u +%Y-%m-%dT%H:%M:%SZ) $COMMAND"
    # Append to validation log
    LOG_FILE=$(state_file validation_log)
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) FAILED: $COMMAND" >> "$LOG_FILE"
fi

exit 0
