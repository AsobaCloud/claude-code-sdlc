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

NEXT ACTION (3 steps in order):
1. Find your SEP number: ls ~/.claude/.sep/ or ls .sep/
2. If none exists: ~/.claude/scripts/sep_create.sh 'title'
3. Re-run git commit with SEP-NNN in the message (e.g., 'SEP-006: Fix error messages')."
