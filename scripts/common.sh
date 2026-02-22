#!/bin/bash
# common.sh — shared library for all Claude hook scripts
# Source this at the top of every hook: source "$(dirname "$0")/common.sh"
#
# Architecture: persist-only state keyed by project directory hash.
# No session-scoped state — session_id changes don't matter.

# ── Require jq ──
if ! command -v jq &>/dev/null; then
    echo "FATAL: jq is required but not found. Install with: brew install jq" >&2
    exit 1
fi

# ── init_hook: read stdin, set up persist dir ──
# Sets: HOOK_INPUT, PERSIST_DIR (project-scoped, pwd-hashed)
init_hook() {
    HOOK_INPUT=$(cat)

    SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null)

    if [[ -z "$SESSION_ID" && -z "$CLAUDE_TEST_PERSIST_DIR" ]]; then
        exit 0
    fi

    # Project-scoped persistent state — single source of truth
    PROJECT_HASH=$(pwd | shasum | cut -c1-12)
    PERSIST_DIR="${CLAUDE_TEST_PERSIST_DIR:-${HOME}/.claude/state/${PROJECT_HASH}}"
    mkdir -p "$PERSIST_DIR"
}

# ── State helpers (all persist-backed) ──
state_file() { echo "${PERSIST_DIR}/$1"; }
state_exists() { [[ -f "${PERSIST_DIR}/$1" ]]; }
state_write() { echo "$2" > "${PERSIST_DIR}/$1"; }
state_read() { cat "${PERSIST_DIR}/$1" 2>/dev/null; }
state_remove() { rm -f "${PERSIST_DIR}/$1"; }

# Legacy aliases — scripts that call persist_* still work
persist_file() { echo "${PERSIST_DIR}/$1"; }
persist_exists() { [[ -f "${PERSIST_DIR}/$1" ]]; }
persist_write() { echo "$2" > "${PERSIST_DIR}/$1"; }
persist_read() { cat "${PERSIST_DIR}/$1" 2>/dev/null; }
persist_remove() { rm -f "${PERSIST_DIR}/$1"; }

# ── JSON field extraction ──
tool_name() { echo "$HOOK_INPUT" | jq -r '.tool_name // empty'; }
tool_input() { echo "$HOOK_INPUT" | jq -r ".tool_input.$1 // empty"; }

# ── Cross-platform file mtime (epoch seconds) ──
file_mtime() {
    local path="$1"
    if [[ "$(uname)" == "Darwin" ]]; then
        stat -f %m "$path" 2>/dev/null || echo 0
    else
        stat -c %Y "$path" 2>/dev/null || echo 0
    fi
}

# ── Hook output: deny tool ──
deny_tool() {
    local reason="$1"
    local hook_event="${2:-PreToolUse}"
    jq -n \
        --arg event "$hook_event" \
        --arg reason "$reason" \
        '{"hookSpecificOutput":{"hookEventName":$event,"permissionDecision":"deny","permissionDecisionReason":$reason}}'
    exit 0
}

# ── Hook output: allow with context ──
allow_with_context() {
    local context="$1"
    local hook_event="${2:-PreToolUse}"
    jq -n \
        --arg event "$hook_event" \
        --arg ctx "$context" \
        '{"hookSpecificOutput":{"hookEventName":$event,"permissionDecision":"allow","additionalContext":$ctx}}'
    exit 0
}
