#!/bin/bash
# SessionStart hook — clean up legacy state and stale SQLite data

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

# SQLite cleanup — remove conversations inactive for 7+ days
ensure_db
db_exec "DELETE FROM state WHERE conversation_id IN (SELECT id FROM conversations WHERE last_active < datetime('now', '-7 days'));"
db_exec "DELETE FROM sessions WHERE conversation_id IN (SELECT id FROM conversations WHERE last_active < datetime('now', '-7 days'));"
db_exec "DELETE FROM events WHERE conversation_id IN (SELECT id FROM conversations WHERE last_active < datetime('now', '-7 days'));"
db_exec "DELETE FROM conversations WHERE last_active < datetime('now', '-7 days');"

# Clean up orphaned flat-file state directories
STATE_DIR="${HOME}/.claude/state"
if [[ -d "$STATE_DIR" ]]; then
    find "$STATE_DIR" -mindepth 2 -maxdepth 2 -type d -empty -delete 2>/dev/null
    find "$STATE_DIR" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null
fi

# Preserve existing token or generate new one (SEP-012)
EXISTING_TOKEN=$(read_conversation_token 2>/dev/null || true)
if [[ -n "$EXISTING_TOKEN" ]]; then
    # Refresh last_active for the existing conversation
    db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('$(sql_escape "$EXISTING_TOKEN")', '$(sql_escape "$(pwd)")');"
    db_exec "UPDATE conversations SET last_active = datetime('now') WHERE id='$(sql_escape "$EXISTING_TOKEN")';"
else
    generate_conversation_token >/dev/null 2>&1
fi

# Check if codebase summary exists and is recent (SEP-022)
PROJECT_MEM_DIR="$HOME/.claude/projects/$(pwd | tr '/' '-' | sed 's/^-//')/memory"
SUMMARY_FILE="$PROJECT_MEM_DIR/summary.md"
if [[ ! -f "$SUMMARY_FILE" ]] || [[ -n "$(find "$SUMMARY_FILE" -mtime +1 2>/dev/null)" ]]; then
    state_write summary_required "1"
fi

exit 0
