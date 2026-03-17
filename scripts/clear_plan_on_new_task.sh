#!/bin/bash
# PostToolUse hook on EnterPlanMode — clears approval, enters planning
# All state is persist-only.
source "$(dirname "$0")/common.sh"
init_hook

# Preserve context breadcrumbs for compaction recovery
prev_obj=$(state_read objective)
prev_plan=$(state_read plan_file)

# Selective clear — remove workflow keys, then plan context keys
clear_workflow_keys
clear_plan_context_keys

# Write breadcrumbs for compaction recovery
[[ -n "$prev_obj" ]] && state_write previous_objective "$prev_obj"
[[ -n "$prev_plan" ]] && state_write previous_plan_file "$prev_plan"

# Enter planning mode
state_write planning "1"
state_write planning_started_at "$(date +%s)"

PLAN_DIR=$(conversation_plan_dir)
echo "Previous plan cleared. Write your plan to ${PLAN_DIR}/<name>.md. Read docs and code before writing a plan."
exit 0
