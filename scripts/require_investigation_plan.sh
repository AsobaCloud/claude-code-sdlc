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

deny_tool "BLOCKED: Diagnostic mode active — investigation plan required.

Tool: ${TOOL}

You asked a diagnostic question. Before investigating, you must:
1. Call EnterPlanMode (this is the only tool available right now)
2. Write an investigation plan with ## Hypothesis, ## Investigation Steps, ## Scope
3. Call ExitPlanMode to get it approved
4. Then all tools will be unlocked for systematic investigation.

The user can type /skip-investigation to bypass this requirement."
