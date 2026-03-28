#!/bin/bash
# PreCompact hook — snapshot workflow state before context compaction (SEP-026)
# Captures phase markers, recent events, and git diff stat into a single state key
# so that post-compaction recovery can restore full context.
source "$(dirname "$0")/common.sh"
init_hook

# ── Determine current phase ──
PHASE="idle"
if state_exists approved; then
    PHASE="approved"
elif state_exists planning; then
    PHASE="planning"
fi

# ── Read phase markers ──
PLAN_FILE_VAL=$(state_read plan_file)
OBJECTIVE_VAL=$(state_read objective)
EDIT_COUNT_VAL=$(state_read edit_count)
DIRTY_VAL=$(state_read dirty)
VALIDATED_UNIT_VAL=$(state_read validated_unit)
VALIDATED_E2E_VAL=$(state_read validated_e2e)
OBJ_VERIFIED_VAL=$(state_read objective_verified)

# ── Query recent events (last 20) ──
RECENT_EVENTS=$(db_query "SELECT timestamp || '|' || event_type || '|' || COALESCE(detail,'') FROM events WHERE conversation_id='$(sql_escape "$CONV_ID")' ORDER BY id DESC LIMIT 20;")

# ── Capture git diff stat (if in a git repo) ──
GIT_DIFF=""
if git rev-parse --is-inside-work-tree &>/dev/null; then
    GIT_DIFF=$(git diff --stat 2>/dev/null || true)
fi

# ── Build structured snapshot ──
SNAPSHOT="SNAPSHOT_TIME: $(date -u +%Y-%m-%dT%H:%M:%SZ)
PHASE: ${PHASE}"

if [[ -n "$GIT_DIFF" ]]; then
    SNAPSHOT="${SNAPSHOT}
GIT_DIFF_STAT:
${GIT_DIFF}"
fi

SNAPSHOT="${SNAPSHOT}
PHASE_MARKERS:"
[[ -n "$PLAN_FILE_VAL" ]] && SNAPSHOT="${SNAPSHOT}
  plan_file: ${PLAN_FILE_VAL}"
[[ -n "$OBJECTIVE_VAL" ]] && SNAPSHOT="${SNAPSHOT}
  objective: ${OBJECTIVE_VAL}"
[[ -n "$EDIT_COUNT_VAL" ]] && SNAPSHOT="${SNAPSHOT}
  edit_count: ${EDIT_COUNT_VAL}"
[[ -n "$DIRTY_VAL" ]] && SNAPSHOT="${SNAPSHOT}
  dirty: ${DIRTY_VAL}"
[[ -n "$VALIDATED_UNIT_VAL" ]] && SNAPSHOT="${SNAPSHOT}
  validated_unit: ${VALIDATED_UNIT_VAL}"
[[ -n "$VALIDATED_E2E_VAL" ]] && SNAPSHOT="${SNAPSHOT}
  validated_e2e: ${VALIDATED_E2E_VAL}"
[[ -n "$OBJ_VERIFIED_VAL" ]] && SNAPSHOT="${SNAPSHOT}
  objective_verified: ${OBJ_VERIFIED_VAL}"

SNAPSHOT="${SNAPSHOT}
RECENT_EVENTS:"
if [[ -n "$RECENT_EVENTS" ]]; then
    SNAPSHOT="${SNAPSHOT}
${RECENT_EVENTS}"
fi

# ── Write snapshot and set compaction flag ──
state_write compaction_snapshot "$SNAPSHOT"
state_write compaction_detected "1"
log_event "precompact_snapshot_taken" "phase=${PHASE}"

exit 0
