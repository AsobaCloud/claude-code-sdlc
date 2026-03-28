#!/bin/bash
# Migrate shared-memory feedback files into the memories + memories_fts tables.
# Idempotent — uses memory_write which does INSERT OR REPLACE.

set -euo pipefail
source "$(dirname "$0")/common.sh"

# No hook context needed — set CONV_ID to avoid init_hook requirement
export CONV_ID="${CONV_ID:-migrate}"
ensure_db

SHARED_MEM="$HOME/.claude/shared-memory"
MIGRATED=0
SKIPPED=0

for f in "$SHARED_MEM"/feedback_*.md; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f" .md)"

    # Parse YAML frontmatter
    name=""
    type=""
    correction_count="1"
    in_frontmatter=false
    frontmatter_done=false
    content_lines=""

    while IFS= read -r line; do
        if [[ "$frontmatter_done" == "false" ]]; then
            if [[ "$line" == "---" && "$in_frontmatter" == "false" ]]; then
                in_frontmatter=true
                continue
            elif [[ "$line" == "---" && "$in_frontmatter" == "true" ]]; then
                frontmatter_done=true
                continue
            fi
            if [[ "$in_frontmatter" == "true" ]]; then
                case "$line" in
                    name:*) name="${line#name: }" ;;
                    type:*) type="${line#type: }" ;;
                    correction_count:*) correction_count="${line#correction_count: }" ;;
                esac
            fi
        else
            # Accumulate content (skip leading empty lines)
            if [[ -n "$content_lines" || -n "$line" ]]; then
                content_lines="${content_lines}${line}
"
            fi
        fi
    done < "$f"

    if [[ -z "$name" ]]; then
        echo "SKIP (no name): $base"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Default type to feedback if not specified
    [[ -z "$type" ]] && type="feedback"

    # Generate keywords from the title
    keywords=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' ' ' | sed 's/^ //;s/ $//')

    # Write to database (anticipated_queries and concept_tags populated by enrich_memories.sh)
    memory_write "$base" "$type" "$name" "$content_lines" "$keywords" "" "$correction_count" "" ""
    echo "OK ($correction_count): $name"
    MIGRATED=$((MIGRATED + 1))
done

echo ""
echo "Migration complete: $MIGRATED migrated, $SKIPPED skipped"
echo "Total in DB: $(db_query "SELECT COUNT(*) FROM memories;")"
echo "Total in FTS: $(db_query "SELECT COUNT(*) FROM memories_fts;")"
