#!/bin/bash
# User skips testing entirely — unlocks both TDD gate and review gate
source "$(dirname "$0")/common.sh"
init_hook

state_write tests_reviewed "$(date -u +%Y-%m-%dT%H:%M:%SZ) skipped"
state_write tests_failed "$(date -u +%Y-%m-%dT%H:%M:%SZ) skipped-by-user"
echo "Tests skipped. Production code editing is now unlocked."
