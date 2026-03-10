#!/bin/bash
# SessionStart hook — clean up legacy state from old session-scoped architecture

# Remove old session directories (no longer used — state is persist-only now)
if [[ -d /tmp/.claude_hooks ]]; then
    find /tmp/.claude_hooks -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} + 2>/dev/null
fi

# Clean legacy flat files from old hook system
find /tmp -maxdepth 1 -name '.claude_*' -mmin +360 -delete 2>/dev/null

# Sync global memory into project memory dir via symlinks
SHARED_MEM="$HOME/.claude/shared-memory"
if [[ -d "$SHARED_MEM" ]]; then
    PROJECT_HASH="$(pwd | tr '/' '-' | sed 's/^-//')"
    PROJECT_MEM="$HOME/.claude/projects/-${PROJECT_HASH}/memory"
    mkdir -p "$PROJECT_MEM"
    for f in "$SHARED_MEM"/*.md; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        target="$PROJECT_MEM/$base"
        # Only create symlink if nothing exists at target
        # (preserves project-specific files with same name)
        if [ ! -e "$target" ]; then
            ln -s "$f" "$target"
        fi
    done
fi

# Generate conversation token for session isolation (SEP-005)
source "$(dirname "$0")/common.sh"
PROJECT_HASH=$(pwd | shasum | cut -c1-12)
PERSIST_DIR="${CLAUDE_TEST_PERSIST_DIR:-${HOME}/.claude/state/${PROJECT_HASH}}"
mkdir -p "$PERSIST_DIR"
generate_conversation_token >/dev/null 2>&1

exit 0
