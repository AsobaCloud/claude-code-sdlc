#!/bin/bash
# Emergency approval restore — rebuilds approval bundle from the current plan
# Usage: ~/.claude/scripts/restore_approval.sh
# No args needed — uses current working directory

source "$(dirname "$0")/common.sh"
init_persist_dir

# Query plans table first, fall back to disk scan
PLAN_FILE=""
DB_PATH=$(db_query "SELECT file_path FROM plans WHERE conversation_id='$(sql_escape "$CONV_ID")' AND status='approved' ORDER BY id DESC LIMIT 1;")
if [[ -n "$DB_PATH" && -f "$DB_PATH" ]] && ! plan_is_done "$DB_PATH"; then
    PLAN_FILE="$DB_PATH"
fi
if [[ -z "$PLAN_FILE" ]]; then
    PLAN_FILE=$(resolve_plan_file)
fi
if [[ -z "$PLAN_FILE" || ! -f "$PLAN_FILE" ]]; then
    state_remove approved
    echo "Approval restore failed for project (hash: ${PROJECT_HASH})."
    echo "No readable plan file found. Create/update a plan in ~/.claude/plans then re-run /approve."
    exit 1
fi

if ! write_approval_bundle "$PLAN_FILE"; then
    state_remove approved
    echo "Approval restore failed for project (hash: ${PROJECT_HASH})."
    echo "Could not extract approval metadata from: ${PLAN_FILE}"
    exit 1
fi

state_remove planning
state_remove planning_started_at

log_event "approval_restored" "$PLAN_FILE"

echo "Approval restored for project (hash: ${PROJECT_HASH})."
echo "Plan: ${PLAN_FILE}"
echo "Will persist across sessions until /accept, /reject, or new plan cycle."
