#!/bin/bash
# Emergency approval restore — rebuilds approval bundle from the current plan
# Usage: ~/.claude/scripts/restore_approval.sh
# No args needed — uses current working directory

source "$(dirname "$0")/common.sh"

PROJECT_HASH=$(pwd | shasum | cut -c1-12)
PERSIST_DIR="${CLAUDE_TEST_PERSIST_DIR:-${HOME}/.claude/state/${PROJECT_HASH}}"
mkdir -p "$PERSIST_DIR"

PLAN_FILE=$(resolve_plan_file_for_manual_approve)
if [[ -z "$PLAN_FILE" || ! -f "$PLAN_FILE" ]]; then
    rm -f "${PERSIST_DIR}/approved"
    echo "Approval restore failed for project (hash: ${PROJECT_HASH})."
    echo "No readable plan file found. Create/update a plan in ~/.claude/plans then re-run /approve."
    exit 1
fi

if ! write_approval_bundle "$PLAN_FILE"; then
    rm -f "${PERSIST_DIR}/approved"
    echo "Approval restore failed for project (hash: ${PROJECT_HASH})."
    echo "Could not extract approval metadata from: ${PLAN_FILE}"
    exit 1
fi

state_remove planning
state_remove planning_started_at

echo "Approval restored for project (hash: ${PROJECT_HASH})."
echo "Plan: ${PLAN_FILE}"
echo "Will persist across sessions until /accept, /reject, or new plan cycle."
