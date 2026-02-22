#!/bin/bash
# PostToolUse hook on EnterPlanMode — clears approval, enters planning
# All state is persist-only.
source "$(dirname "$0")/common.sh"
init_hook

# Clear all approval state
state_remove approved
state_remove objective
state_remove scope
state_remove criteria
state_remove plan_file

# Enter planning mode
state_write planning "1"

echo "Previous plan cleared. Read docs and code before writing a plan."
exit 0
