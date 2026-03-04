#!/bin/bash
# PostToolUse hook on Edit|Write|NotebookEdit — sets dirty flag for non-exempt edits
source "$(dirname "$0")/common.sh"
init_hook

FILE_PATH=$(tool_input file_path)
[[ -z "$FILE_PATH" ]] && FILE_PATH=$(tool_input notebook_path)
[[ -z "$FILE_PATH" ]] && exit 0

# Skip exempt paths (same exclusions as require_plan_approval.sh)
[[ "$FILE_PATH" == *"/.claude/plans/"* ]] && exit 0
[[ "$FILE_PATH" == *"/.sep/"* ]] && exit 0
[[ "$FILE_PATH" == *"/.claude/projects/"*"/memory/"* ]] && exit 0

# Set dirty marker with timestamp
state_write dirty "$(date -u +%Y-%m-%dT%H:%M:%SZ) $FILE_PATH"
exit 0
