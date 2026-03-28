#!/bin/bash
# SessionEnd hook — delete conversation transcripts older than 5 days
# The SQLite workflow.db retains the decision record (objectives, plans,
# scope, criteria, events). Raw transcripts beyond 5 days are redundant.

find "$HOME/.claude/projects" -name "*.jsonl" -mtime +5 -delete 2>/dev/null

# Clean empty session directories left behind
find "$HOME/.claude/projects" -mindepth 2 -maxdepth 2 -type d -empty -delete 2>/dev/null

exit 0
