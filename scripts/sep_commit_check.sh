#!/bin/bash
# PreToolUse hook on Bash — ensures git commits reference a SEP issue
source "$(dirname "$0")/common.sh"
init_hook

COMMAND=$(tool_input command)

# Only check git commit commands
if ! echo "$COMMAND" | grep -qE 'git\s+commit'; then
    exit 0
fi

# Skip exempt projects
if [[ -f "${CLAUDE_PROJECT_DIR:-.}/.sep-exempt" ]]; then
    exit 0
fi

# Check for SEP reference in the command (commit message)
if echo "$COMMAND" | grep -qE 'SEP-[0-9]+'; then
    exit 0
fi

deny_tool "BLOCKED: git commit must reference a SEP issue in the commit message.
Include 'SEP-NNN' in your commit message (e.g., 'SEP-012: Add batch size config').
If no SEP exists, create one first: ~/.claude/scripts/sep_create.sh"
