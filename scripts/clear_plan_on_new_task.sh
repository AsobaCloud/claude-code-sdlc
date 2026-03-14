#!/bin/bash
# PostToolUse hook on EnterPlanMode — clears approval, enters planning
# All state is persist-only.
source "$(dirname "$0")/common.sh"
init_hook

# Clear all state from previous plan cycle
clear_all_state

# Enter planning mode
state_write planning "1"
state_write planning_started_at "$(date +%s)"

PLAN_DIR=$(conversation_plan_dir)
echo "Previous plan cleared. Write your plan to ${PLAN_DIR}/<name>.md. Read docs and code before writing a plan."
exit 0
