#!/bin/bash
# Enrich existing memories with anticipated_queries and concept_tags.
# Idempotent — overwrites previous enrichment values.

set -euo pipefail
source "$(dirname "$0")/common.sh"

export CONV_ID="${CONV_ID:-enrich}"
ensure_db

ENRICHED=0

enrich() {
    local id="$1" queries="$2" tags="$3"
    python3 -c "
import sqlite3, sys
db = sqlite3.connect('$WORKFLOW_DB')
db.execute('UPDATE memories SET anticipated_queries=?, concept_tags=?, updated_at=CAST(strftime(\"%s\",\"now\") AS INTEGER) WHERE id=?',
(sys.argv[1], sys.argv[2], sys.argv[3]))
db.commit()
" "$queries" "$tags" "$id"
    # Rebuild FTS entry for this memory
    local rowid title content keywords
    rowid=$(db_query "SELECT rowid FROM memories WHERE id='$(sql_escape "$id")';")
    if [[ -n "$rowid" ]]; then
        sqlite3 "$WORKFLOW_DB" "DELETE FROM memories_fts WHERE rowid = $rowid;"
        python3 -c "
import sqlite3, sys
db = sqlite3.connect('$WORKFLOW_DB')
row = db.execute('SELECT title, content, keywords, anticipated_queries FROM memories WHERE id=?', (sys.argv[1],)).fetchone()
if row:
    db.execute('INSERT INTO memories_fts(rowid, title, content, keywords, anticipated_queries) VALUES (?, ?, ?, ?, ?)',
    (int(sys.argv[2]), row[0], row[1] or '', row[2] or '', row[3] or ''))
    db.commit()
" "$id" "$rowid"
        echo "OK: $id"
        ENRICHED=$((ENRICHED + 1))
    else
        echo "SKIP (not found): $id"
    fi
}

# ── Enrichment data for all 13 memories ──

enrich "feedback_read_before_acting" \
    "how to avoid skimming, stop pattern matching, read docs before asking, RTFM, read hooks before reacting, why does claude skip reading, read transcripts after compaction, read everything before acting" \
    "|feedback/workflow|feedback/epistemics|feedback/reading|"

enrich "feedback_dont_ask_act" \
    "stop asking permission, unnecessary confirmation, don't re-confirm, stop seeking validation, why does claude keep asking, just do it, act without asking, redundant permission requests" \
    "|feedback/workflow|feedback/autonomy|feedback/communication|"

enrich "feedback_thoroughness_over_speed" \
    "rushing causes bugs, don't ship broken code, verify before declaring done, speed vs quality, false completion, broken references, skipping validation, cutting corners" \
    "|feedback/quality|feedback/workflow|feedback/validation|"

enrich "feedback_follow_instructions" \
    "follow CLAUDE.md, follow instructions literally, restate objective before coding, don't interpret which rules apply, mechanical compliance, user instructions are rules not suggestions" \
    "|feedback/workflow|feedback/compliance|feedback/planning|"

enrich "feedback_engineer_mindset" \
    "senior engineer thinking, product outcome vs task completion, verify plan claims, don't replan incomplete work, own the system, holistic thinking, end to end understanding" \
    "|feedback/mindset|feedback/quality|feedback/planning|"

enrich "feedback_investigate_before_action" \
    "root cause analysis, investigate before workaround, why does similar thing work, use sqlite for recovery, conversation token lookup, compaction recovery, don't guess at state" \
    "|feedback/debugging|feedback/workflow|feedback/recovery|"

enrich "feedback_test_scope" \
    "test the objective not the implementation, circular tests, tautological tests, smoke tests are insufficient, test edge cases, verify real behavior not string patterns" \
    "|feedback/testing|feedback/quality|feedback/tdd|"

enrich "feedback_no_db_patching" \
    "don't modify workflow.db directly, no sqlite3 patches, use hook scripts, database integrity, workflow state corruption, bypass hook system" \
    "|feedback/workflow|feedback/hooks|feedback/integrity|"

enrich "feedback_delegate_to_tdd_agent" \
    "use tdd-test-writer agent, epistemic isolation for tests, don't write tests in main context, delegate test writing, agent delegation, test independence" \
    "|feedback/testing|feedback/tdd|feedback/agents|"

enrich "feedback_architecture_docs_target_state" \
    "architecture docs describe correct design, don't document bugs as contract, target state not current state, canonical documentation" \
    "|feedback/documentation|feedback/architecture|"

enrich "feedback_no_mocked_test_data" \
    "tests must use real data, no mocked test data, tautological tests, mock validates implementation against itself, end to end testing, real behavior" \
    "|feedback/testing|feedback/quality|feedback/tdd|"

enrich "feedback_no_unauthorized_design_changes" \
    "no sneaking design changes, unauthorized architectural decisions, scope creep, approval required for design changes, trust violation" \
    "|feedback/workflow|feedback/trust|feedback/planning|"

enrich "feedback_trace_all_dependencies" \
    "trace all consumers on refactor, update read paths not just write paths, end to end refactoring, grep for all callers, integration testing after refactor" \
    "|feedback/refactoring|feedback/quality|feedback/testing|"

echo ""
echo "Enrichment complete: $ENRICHED memories updated"
echo "Verification:"
echo "  anticipated_queries populated: $(db_query "SELECT COUNT(*) FROM memories WHERE anticipated_queries IS NOT NULL AND anticipated_queries != '';")"
echo "  concept_tags populated: $(db_query "SELECT COUNT(*) FROM memories WHERE concept_tags IS NOT NULL AND concept_tags != '';")"
