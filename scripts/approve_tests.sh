#!/bin/bash
# User approves tests after review — unlocks production code editing
source "$(dirname "$0")/common.sh"
init_hook

state_write tests_reviewed "$(date -u +%Y-%m-%dT%H:%M:%SZ) approved"
echo "Tests approved. Production code editing is now unlocked."
