#!/bin/bash
# SessionStart hook — clean up legacy state from old session-scoped architecture

# Remove old session directories (no longer used — state is persist-only now)
if [[ -d /tmp/.claude_hooks ]]; then
    find /tmp/.claude_hooks -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} + 2>/dev/null
fi

# Clean legacy flat files from old hook system
find /tmp -maxdepth 1 -name '.claude_*' -mmin +360 -delete 2>/dev/null

exit 0
