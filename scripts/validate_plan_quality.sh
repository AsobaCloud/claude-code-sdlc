#!/bin/bash
# PreToolUse hook on ExitPlanMode — quality gate + approval creation
# All state is persist-only (no session-scoped state).
source "$(dirname "$0")/common.sh"
init_hook

ERRORS=""

# ── Check 1: Resolve plan file ──
PLAN_FILE=$(resolve_plan_file_for_exit_plan)

if [[ -z "$PLAN_FILE" ]]; then
    deny_tool "BLOCKED: No plan file found in ~/.claude/plans/ or .claude/plans/

NEXT ACTION: Write your plan to ~/.claude/plans/<name>.md using the Write tool, then call ExitPlanMode."
fi

NEWEST_TIME=$(file_mtime "$PLAN_FILE")

# Check staleness (4 hours)
AGE=$(( $(date +%s) - NEWEST_TIME ))
if [[ "$AGE" -gt 14400 ]]; then
    ERRORS+="STALE PLAN: $(( AGE / 60 )) minutes old (max 240).
  File: $PLAN_FILE

  NEXT ACTION: Open the plan file with Read, review the content, make any necessary updates with Edit, then call ExitPlanMode. Do NOT make trivial edits just to reset the timestamp.

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
        SCOPE_LINES=$(echo "$SCOPE_CONTENT" | grep -E '^\s*-\s+/')
        if [[ -z "$SCOPE_LINES" ]]; then
            ERRORS+="## Scope entries must be EXACT absolute filesystem paths. Format: '- /absolute/path/to/file.ext' (one per line). PROHIBITED: backticks, '(new)', comments, annotations, relative paths, glob patterns. Only literal paths that exist or will be created.

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
            ERRORS+="## Justification must cite specific project files you read. Pattern: 'Because [path/to/file.ext] shows [what you found], this plan [does X].' Do NOT add file names without explaining what they told you.

"
        fi

        if ! echo "$JUST_CONTENT" | grep -qiE '(because|consistent with|per |therefore|aligns with|following the|in line with|as documented|as specified|this follows|this matches)'; then
            ERRORS+="## Justification must contain causal reasoning connecting evidence to your approach. Use 'because', 'therefore', 'per', etc. to explain WHY, not just WHAT.

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

    # Objective Verification (required for code-change plans)
    if plan_requires_objective_verification "$PLAN_FILE"; then
        if ! echo "$PLAN_CONTENT" | grep -qiE '^##\s+Objective\s+Verification'; then
            ERRORS+="MISSING ## Objective Verification section.
  Code-change plans must define the real end-to-end verification step for the plan objective.

"
        else
            OBJ_VERIFY_CONTENT=$(extract_plan_objective_verification "$PLAN_FILE")
            OBJ_VERIFY_WORDS=$(echo "$OBJ_VERIFY_CONTENT" | wc -w | tr -d ' ')
            if [[ "$OBJ_VERIFY_WORDS" -lt 10 ]]; then
                ERRORS+="## Objective Verification too short ($OBJ_VERIFY_WORDS words, minimum 10).
  Describe the real end-to-end verification step that proves the objective works.

"
            fi
        fi
    fi

    # ── Check 6: SEP issue reference (skip for exempt projects) ──
    if [[ ! -f "${CLAUDE_PROJECT_DIR:-.}/.sep-exempt" ]]; then
        SEP_REF=$(echo "$PLAN_CONTENT" | grep -oE 'SEP-[0-9]+' | head -1)
        if [[ -z "$SEP_REF" ]]; then
            ERRORS+="NO SEP REFERENCE: Plan must reference a SEP issue (e.g., 'Implements SEP-003').

  NEXT ACTION (4 steps in order):
  1. List existing SEPs: ls ~/.claude/.sep/ or ls .sep/
  2. If none fits, create one: ~/.claude/scripts/sep_create.sh 'title' 'summary' 'motivation' 'change' 'criteria'
  3. Add 'Implements SEP-NNN' to your plan's ## Objective.
  4. Call ExitPlanMode again.

"
        fi
    fi

fi  # end IS_INVESTIGATION branch

# ── Emit all errors at once, or pass ──
if [[ -n "$ERRORS" ]]; then
    deny_tool "BLOCKED: Plan quality checks failed.

${ERRORS}NEXT ACTION: Fix all issues above in your plan file, then call ExitPlanMode again."
fi

# ── All checks passed — create coherent approval bundle ──
if ! write_approval_bundle "$PLAN_FILE"; then
    deny_tool "BLOCKED: Failed to persist approval metadata from plan.

NEXT ACTION: Verify the plan file is readable, then call ExitPlanMode again."
fi

# Append to plan history log (project + global)
PLAN_DATE=$(date '+%Y-%m-%d %H:%M')
PLAN_OBJECTIVE=$(extract_plan_objective "$PLAN_FILE" | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-120)
HISTORY_LINE="- ${PLAN_DATE} | ${PLAN_OBJECTIVE} [${PLAN_FILE##*/}]"

# Project-scoped history
PROJECT_HASH_DIR=$(pwd | tr '/' '-' | sed 's/^-//')
PROJECT_MEM="$HOME/.claude/projects/-${PROJECT_HASH_DIR}/memory"
mkdir -p "$PROJECT_MEM"
echo "$HISTORY_LINE" >> "$PROJECT_MEM/plan-history.md"

# Global history
SHARED_MEM="$HOME/.claude/shared-memory"
if [[ -d "$SHARED_MEM" ]]; then
    echo "$HISTORY_LINE" >> "$SHARED_MEM/plan-history.md"
fi

# Store conversation token with approval (SEP-005)
CONV_TOKEN=$(read_conversation_token)
if [[ -n "$CONV_TOKEN" ]]; then
    state_write approval_token "$CONV_TOKEN"
fi

# Clean up planning state
state_remove planning
state_remove planning_started_at

if [[ "$IS_INVESTIGATION" == "true" ]]; then
    allow_with_context "Investigation plan approved. Tools unlocked. Execute your investigation systematically, citing evidence for every finding. When done, run ~/.claude/scripts/clear_approval.sh then tell the user to /accept or /reject."
else
    allow_with_context "Plan approved. Editing unlocked. Implement ONLY the approved changes. Before calling clear_approval.sh, record objective verification for the approved plan using ~/.claude/scripts/record_validation.sh --command \"<approved verification command>\". If you cannot verify the objective, report objective unverified and stop. Do NOT tell the user to /accept unless objective verification has been recorded."
fi
