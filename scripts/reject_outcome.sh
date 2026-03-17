#!/bin/bash
# Called by /reject command — clears approval after user rejects implementation

set -euo pipefail

source "$(dirname "$0")/common.sh"
init_persist_dir

# Update plans table: mark current plan as 'rejected'
CURRENT_PLAN_ID=$(db_query "SELECT id FROM plans WHERE conversation_id='$(sql_escape "$CONV_ID")' AND status='approved' ORDER BY id DESC LIMIT 1;")
if [[ -n "$CURRENT_PLAN_ID" ]]; then
    update_plan_status "$CURRENT_PLAN_ID" "rejected"
fi

# Selective clear — remove workflow keys and plan context keys
clear_workflow_keys
clear_plan_context_keys

echo "Implementation rejected. Plan approval cleared. Provide feedback for re-planning."
