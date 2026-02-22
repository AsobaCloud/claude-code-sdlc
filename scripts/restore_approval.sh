#!/bin/bash
# Emergency approval restore — sets project approval
# Usage: ~/.claude/scripts/restore_approval.sh
# No args needed — uses current working directory

PROJECT_HASH=$(pwd | shasum | cut -c1-12)
PERSIST_DIR="${CLAUDE_TEST_PERSIST_DIR:-${HOME}/.claude/state/${PROJECT_HASH}}"
mkdir -p "$PERSIST_DIR"

echo "1" > "${PERSIST_DIR}/approved"

echo "Approval restored for project (hash: ${PROJECT_HASH})."
echo "Will persist across sessions until /accept, /reject, or new plan cycle."
