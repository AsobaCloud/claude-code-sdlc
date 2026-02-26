#!/bin/bash
# PreToolUse hook on ExitPlanMode — quality gate + approval creation
# All state is persist-only (no session-scoped state).
source "$(dirname "$0")/common.sh"
init_hook

ERRORS=""

# ── Check 1: Find plan file ──
PLAN_FILE=""
NEWEST_TIME=0

for DIR in ~/.claude/plans .claude/plans; do
    [[ ! -d "$DIR" ]] && continue
    while IFS= read -r -d '' F; do
        FTIME=$(file_mtime "$F")
        if [[ "$FTIME" -gt "$NEWEST_TIME" ]]; then
            NEWEST_TIME=$FTIME
            PLAN_FILE=$F
        fi
    done < <(find "$DIR" -maxdepth 1 -name '*.md' -print0 2>/dev/null)
done

if [[ -z "$PLAN_FILE" ]]; then
    deny_tool "BLOCKED: No plan file found in ~/.claude/plans/ or .claude/plans/

NEXT ACTION: Write your plan to a .md file in the plans directory, then call ExitPlanMode."
fi

# Check staleness (4 hours)
AGE=$(( $(date +%s) - NEWEST_TIME ))
if [[ "$AGE" -gt 14400 ]]; then
    ERRORS+="STALE PLAN: $(( AGE / 60 )) minutes old (max 240).
  File: $PLAN_FILE

  NEXT ACTION: Update the plan file, then call ExitPlanMode again.

"
fi

# Read plan content
PLAN_CONTENT=$(cat "$PLAN_FILE" 2>/dev/null)

# ── Detect investigation plan (## Hypothesis present) ──
IS_INVESTIGATION=false
if echo "$PLAN_CONTENT" | grep -qiE '^##\s+Hypothesis'; then
    IS_INVESTIGATION=true
fi

# ── Check 2: Word count ──
WORD_COUNT=$(echo "$PLAN_CONTENT" | wc -w | tr -d ' ')
if [[ "$WORD_COUNT" -lt 50 ]]; then
    ERRORS+="PLAN TOO THIN: $WORD_COUNT words (minimum 50).

"
fi

if [[ "$IS_INVESTIGATION" == "true" ]]; then
    # ════════════════════════════════════════════════════
    # INVESTIGATION PLAN VALIDATION (relaxed rules)
    # ════════════════════════════════════════════════════

    # Objective (≥10 words)
    if ! echo "$PLAN_CONTENT" | grep -qiE '^##\s+Objective'; then
        ERRORS+="MISSING ## Objective section (what you are investigating and why).

"
    else
        OBJ_CONTENT=$(echo "$PLAN_CONTENT" | sed -n '/^##[[:space:]]*[Oo]bjective/,/^##/p' | tail -n +2 | grep -v '^## ')
        OBJ_WORDS=$(echo "$OBJ_CONTENT" | wc -w | tr -d ' ')
        if [[ "$OBJ_WORDS" -lt 10 ]]; then
            ERRORS+="## Objective too short ($OBJ_WORDS words, minimum 10).

"
        fi
    fi

    # Hypothesis (≥15 words) — investigation-specific
    HYP_CONTENT=$(echo "$PLAN_CONTENT" | sed -n '/^##[[:space:]]*[Hh]ypothesis/,/^##/p' | tail -n +2 | grep -v '^## ')
    HYP_WORDS=$(echo "$HYP_CONTENT" | wc -w | tr -d ' ')
    if [[ "$HYP_WORDS" -lt 15 ]]; then
        ERRORS+="## Hypothesis too short ($HYP_WORDS words, minimum 15).
  State what might be wrong with explicit confidence levels.

"
    fi

    # Investigation Steps (≥20 words) — investigation-specific
    if ! echo "$PLAN_CONTENT" | grep -qiE '^##\s+Investigation\s+Steps'; then
        ERRORS+="MISSING ## Investigation Steps section (specific checks to run).

"
    else
        STEPS_CONTENT=$(echo "$PLAN_CONTENT" | sed -n '/^##[[:space:]]*[Ii]nvestigation[[:space:]]*[Ss]teps/,/^##/p' | tail -n +2 | grep -v '^## ')
        STEPS_WORDS=$(echo "$STEPS_CONTENT" | wc -w | tr -d ' ')
        if [[ "$STEPS_WORDS" -lt 20 ]]; then
            ERRORS+="## Investigation Steps too short ($STEPS_WORDS words, minimum 20).

"
        fi
    fi

    # Scope (required but relaxed — no file path requirement for investigations)
    if ! echo "$PLAN_CONTENT" | grep -qiE '^##\s+Scope'; then
        ERRORS+="MISSING ## Scope section (systems, files, or logs to examine).

"
    fi

    # Success Criteria (≥10 words)
    if ! echo "$PLAN_CONTENT" | grep -qiE '^##\s+Success\s+Criteria'; then
        ERRORS+="MISSING ## Success Criteria section (how to know investigation is complete).

"
    else
        CRIT_CONTENT=$(echo "$PLAN_CONTENT" | sed -n '/^##[[:space:]]*[Ss]uccess[[:space:]]*[Cc]riteria/,/^##/p' | tail -n +2 | grep -v '^## ')
        CRIT_WORDS=$(echo "$CRIT_CONTENT" | wc -w | tr -d ' ')
        if [[ "$CRIT_WORDS" -lt 10 ]]; then
            ERRORS+="## Success Criteria too short ($CRIT_WORDS words, minimum 10).

"
        fi
    fi

    # Validation (≥20 words — what's known vs assumed)
    if ! echo "$PLAN_CONTENT" | grep -qiE '^##\s+Validation'; then
        ERRORS+="MISSING ## Validation section (what is known vs. assumed before investigating).

"
    else
        VAL_CONTENT=$(echo "$PLAN_CONTENT" | sed -n '/^##[[:space:]]*[Vv]alidation/,/^##/p' | head -50 | tail -n +2 | grep -v '^## ')
        VAL_WORDS=$(echo "$VAL_CONTENT" | wc -w | tr -d ' ')
        if [[ "$VAL_WORDS" -lt 20 ]]; then
            ERRORS+="## Validation too short ($VAL_WORDS words, minimum 20).

"
        fi
    fi

    # SKIPPED for investigations: Justification, SEP reference, file path references,
    # exploration evidence (investigation is the exploration)

else
    # ════════════════════════════════════════════════════
    # STANDARD CODE-CHANGE PLAN VALIDATION (existing rules)
    # ════════════════════════════════════════════════════

    # ── Check 3: File path references ──
    if ! echo "$PLAN_CONTENT" | grep -qE '\.[a-zA-Z]{2,5}\b'; then
        ERRORS+="NO FILE REFERENCES: Plan must reference specific files (e.g., scripts/foo.sh).

"
    fi

    # ── Check 4: Exploration evidence ──
    if ! echo "$PLAN_CONTENT" | grep -qiE '(existing|found|pattern|readme|documentation|current|already|currently)'; then
        ERRORS+="NO EXPLORATION EVIDENCE: Reference what you found in the codebase.

"
    fi

    # ── Check 5: Required sections ──

    # Objective
    if ! echo "$PLAN_CONTENT" | grep -qiE '^##\s+Objective'; then
        ERRORS+="MISSING ## Objective section (what you are doing and why).

"
    else
        OBJ_CONTENT=$(echo "$PLAN_CONTENT" | sed -n '/^##[[:space:]]*[Oo]bjective/,/^##/p' | tail -n +2 | grep -v '^## ')
        OBJ_WORDS=$(echo "$OBJ_CONTENT" | wc -w | tr -d ' ')
        if [[ "$OBJ_WORDS" -lt 10 ]]; then
            ERRORS+="## Objective too short ($OBJ_WORDS words, minimum 10).

"
        fi
    fi

    # Scope
    if ! echo "$PLAN_CONTENT" | grep -qiE '^##\s+Scope'; then
        ERRORS+="MISSING ## Scope section (list every file to be modified).

"
    else
        SCOPE_CONTENT=$(echo "$PLAN_CONTENT" | sed -n '/^##[[:space:]]*[Ss]cope/,/^##/p' | tail -n +2 | grep -v '^## ')
        SCOPE_LINES=$(echo "$SCOPE_CONTENT" | grep -E '^\s*-\s+.*/' | grep -E '\.[a-zA-Z]{1,10}(\s|$|`|\))')
        if [[ -z "$SCOPE_LINES" ]]; then
            ERRORS+="## Scope has no file paths (need '- path/to/file.ext' lines).

"
        fi
    fi

    # Success Criteria
    if ! echo "$PLAN_CONTENT" | grep -qiE '^##\s+Success\s+Criteria'; then
        ERRORS+="MISSING ## Success Criteria section (how to verify the task is done).

"
    else
        CRIT_CONTENT=$(echo "$PLAN_CONTENT" | sed -n '/^##[[:space:]]*[Ss]uccess[[:space:]]*[Cc]riteria/,/^##/p' | tail -n +2 | grep -v '^## ')
        CRIT_WORDS=$(echo "$CRIT_CONTENT" | wc -w | tr -d ' ')
        if [[ "$CRIT_WORDS" -lt 10 ]]; then
            ERRORS+="## Success Criteria too short ($CRIT_WORDS words, minimum 10).

"
        fi
    fi

    # Justification
    if ! echo "$PLAN_CONTENT" | grep -qiE '^##\s+Justification'; then
        ERRORS+="MISSING ## Justification section (why this approach, citing project docs).

"
    else
        JUST_CONTENT=$(echo "$PLAN_CONTENT" | sed -n '/^##[[:space:]]*[Jj]ustification/,/^##/p' | head -50 | tail -n +2 | grep -v '^## ')

        if ! echo "$JUST_CONTENT" | grep -qE '(docs/|scripts/|tools/|assets/|scenes/|CLAUDE\.md|README|\.gd|\.md|\.tscn|\.tres|\.sh|\.json|\.py|\.js|\.ts)'; then
            ERRORS+="## Justification has no project file citations.

"
        fi

        if ! echo "$JUST_CONTENT" | grep -qiE '(because|consistent with|per |therefore|aligns with|following the|in line with|as documented|as specified|this follows|this matches)'; then
            ERRORS+="## Justification lacks reasoning language (because, per, therefore, etc.).

"
        fi
    fi

    # Validation
    if ! echo "$PLAN_CONTENT" | grep -qiE '^##\s+Validation'; then
        ERRORS+="MISSING ## Validation section. Every plan must answer:
  - What sources did you consult? (specific files, docs, URLs)
  - For each fix: what evidence supports it? (causal link, not vibes)
  - What is verified vs. assumed?
  - What are the known gaps?
  - For architecture changes: cite ≥2 external sources (not codebase).

"
    else
        VAL_CONTENT=$(echo "$PLAN_CONTENT" | sed -n '/^##[[:space:]]*[Vv]alidation/,/^##/p' | head -50 | tail -n +2 | grep -v '^## ')
        VAL_WORDS=$(echo "$VAL_CONTENT" | wc -w | tr -d ' ')
        if [[ "$VAL_WORDS" -lt 20 ]]; then
            ERRORS+="## Validation too short ($VAL_WORDS words, minimum 20).

"
        fi

        # Architecture changes need external sources
        if echo "$PLAN_CONTENT" | grep -qiE '(architect|refactor|redesign|restructure|migrate|rewrite|eliminate.*state|single source of truth)'; then
            EXT_SOURCES=$(echo "$VAL_CONTENT" | grep -ciE '(http|docs\.|documentation|spec|RFC|official|reference|per .*docs)')
            if [[ "$EXT_SOURCES" -lt 2 ]]; then
                ERRORS+="## Validation: Architecture change detected but <2 external source citations.
  Consult official docs, specs, or references outside the codebase to validate your approach.

"
            fi
        fi
    fi

    # ── Check 6: SEP issue reference (skip for exempt projects) ──
    if [[ ! -f "${CLAUDE_PROJECT_DIR:-.}/.sep-exempt" ]]; then
        SEP_REF=$(echo "$PLAN_CONTENT" | grep -oE 'SEP-[0-9]+' | head -1)
        if [[ -z "$SEP_REF" ]]; then
            ERRORS+="NO SEP REFERENCE: Plan must reference a SEP issue (e.g., 'Implements SEP-003').

  NEXT ACTION: Run ~/.claude/scripts/sep_create.sh \"title\" to create one,
  then add 'SEP-NNN' to your plan's Objective section.

"
        fi
    fi

fi  # end IS_INVESTIGATION branch

# ── Emit all errors at once, or pass ──
if [[ -n "$ERRORS" ]]; then
    deny_tool "BLOCKED: Plan quality checks failed.

${ERRORS}NEXT ACTION: Fix all issues above in your plan file, then call ExitPlanMode again."
fi

# ── All checks passed — create approval and extract plan sections ──
state_write plan_file "$PLAN_FILE"
state_write approved "1"

# Extract Objective
OBJ=$(echo "$PLAN_CONTENT" \
    | sed -n '/^##[[:space:]]*[Oo]bjective/,/^##/p' \
    | tail -n +2 | grep -v '^## ' \
    | sed '/^[[:space:]]*$/d' \
    | head -3)
state_write objective "$OBJ"

# Extract Scope — strip description suffixes after ' — ' or ' - ' that follow file paths
SCOPE=$(echo "$PLAN_CONTENT" \
    | sed -n '/^##[[:space:]]*[Ss]cope/,/^##/p' \
    | tail -n +2 | grep -v '^## ' \
    | grep -E '^\s*-\s+' \
    | grep '/' \
    | sed 's/^[[:space:]]*-[[:space:]]*//' \
    | sed 's/[[:space:]]*$//' \
    | sed 's/`//g' \
    | sed 's/ — .*//' \
    | sed 's/ - [A-Z].*//')
state_write scope "$SCOPE"

# Extract Success Criteria
CRIT=$(echo "$PLAN_CONTENT" \
    | sed -n '/^##[[:space:]]*[Ss]uccess[[:space:]]*[Cc]riteria/,/^##/p' \
    | tail -n +2 | grep -v '^## ' \
    | sed '/^[[:space:]]*$/d' \
    | head -3)
state_write criteria "$CRIT"

# Clean up planning state
state_remove planning

if [[ "$IS_INVESTIGATION" == "true" ]]; then
    allow_with_context "Investigation plan approved. Tools unlocked. Execute your investigation systematically, citing evidence for every finding. When done, run ~/.claude/scripts/clear_approval.sh then tell the user to /accept or /reject."
else
    allow_with_context "Plan approved. Editing unlocked. Implement ONLY the approved changes. When done, run ~/.claude/scripts/clear_approval.sh then tell the user to /accept or /reject."
fi
