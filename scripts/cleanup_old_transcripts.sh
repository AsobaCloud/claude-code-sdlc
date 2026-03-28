#!/bin/bash
# SessionEnd hook — cleanup transcripts and apply memory attention decay
# The SQLite workflow.db retains the decision record (objectives, plans,
# scope, criteria, events). Raw transcripts beyond 5 days are redundant.

find "$HOME/.claude/projects" -name "*.jsonl" -mtime +5 -delete 2>/dev/null

# Clean empty session directories left behind
find "$HOME/.claude/projects" -mindepth 2 -maxdepth 2 -type d -empty -delete 2>/dev/null

# ── Memory attention decay (SEP-019) ──
# Type-specific decay rates applied at session boundaries.
# Frequently accessed memories resist decay via access boost in UserPromptSubmit.
source "$(dirname "$0")/common.sh"
export CONV_ID="${CONV_ID:-sessionend}"
ensure_db

# Feedback: moderate decay (0.95 retention per session)
db_exec "UPDATE memories SET attention_score = MAX(0.0, COALESCE(attention_score, 0.5) * 0.95) WHERE type = 'feedback';"
# Pattern/preference: slow decay (0.98 retention)
db_exec "UPDATE memories SET attention_score = MAX(0.0, COALESCE(attention_score, 0.5) * 0.98) WHERE type IN ('pattern', 'preference');"
# Task/note: fast decay (0.85 retention)
db_exec "UPDATE memories SET attention_score = MAX(0.0, COALESCE(attention_score, 0.5) * 0.85) WHERE type IN ('task', 'note');"
# Gotcha: slow decay (0.97 retention)
db_exec "UPDATE memories SET attention_score = MAX(0.0, COALESCE(attention_score, 0.5) * 0.97) WHERE type = 'gotcha';"

exit 0
