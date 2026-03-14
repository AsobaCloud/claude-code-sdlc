#!/bin/bash
# PreToolUse hook on Read|Grep|Glob|Bash|Task|WebFetch|WebSearch
# Blocks these tools when diagnostic_mode is active without planning or approved state.
# This forces Claude through the investigation plan pipeline before investigating.
source "$(dirname "$0")/common.sh"
init_hook

# ── Only relevant when diagnostic_mode is active ──
if ! state_exists diagnostic_mode; then
    exit 0
fi

# ── If planning or approved, tools are unlocked ──
if state_exists planning; then
    exit 0
fi
if state_exists approved; then
    exit 0
fi

# ── diagnostic_mode active, no planning, no approval → block ──
TOOL=$(tool_name)

PLAN_DIR=$(conversation_plan_dir)
deny_tool "BLOCKED: Diagnostic mode active — investigation plan required.

Tool: ${TOOL}

NEXT ACTION (4 steps in order):
1. Call EnterPlanMode.
2. Write investigation plan to ${PLAN_DIR}/<name>.md with ALL of: ## Objective (≥10 words), ## Hypothesis (≥15 words, include confidence levels), ## Investigation Steps (≥20 words), ## Scope, ## Success Criteria (≥10 words), ## Validation (≥20 words, what is known vs assumed).
3. Call ExitPlanMode.
4. Then investigate.

The user can type /skip-investigation to bypass this requirement."
