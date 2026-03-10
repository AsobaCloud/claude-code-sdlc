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
counter_increment() {
    local key="$1"
    local value=0
    if state_exists "$key"; then
        value=$(state_read "$key")
    fi
    [[ "$value" =~ ^[0-9]+$ ]] || value=0
    value=$(( value + 1 ))
    state_write "$key" "$value"
    echo "$value"
}

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

# ── Plan helpers ──
normalize_plan_path() {
    local raw="$1"
    raw=$(echo "$raw" | tr -d '\r')
    raw="${raw%\"}"
    raw="${raw#\"}"
    raw="${raw%\'}"
    raw="${raw#\'}"
    echo "$raw"
}

# Check if a plan file is marked as completed
plan_is_done() {
    local plan_file="$1"
    [[ -z "$plan_file" || ! -f "$plan_file" ]] && return 1
    head -3 "$plan_file" | grep -q '^\*\*Status: DONE\*\*'
}

newest_plan_file() {
    local min_time="${1:-0}"
    local newest_time=0
    local plan_file=""
    local dir f ftime

    [[ "$min_time" =~ ^[0-9]+$ ]] || min_time=0

    for dir in "${HOME}/.claude/plans" ".claude/plans"; do
        [[ ! -d "$dir" ]] && continue
        while IFS= read -r -d '' f; do
            ftime=$(file_mtime "$f")
            [[ "$ftime" -lt "$min_time" ]] && continue
            plan_is_done "$f" && continue
            if [[ "$ftime" -gt "$newest_time" ]]; then
                newest_time="$ftime"
                plan_file="$f"
            fi
        done < <(find "$dir" -maxdepth 1 -name '*.md' -print0 2>/dev/null)
    done

    [[ -n "$plan_file" ]] && echo "$plan_file"
}

active_plan_path_from_marker() {
    local marker plan_file

    for marker in "${HOME}/.claude/.claude_active_plan" "${HOME}/.claude_active_plan"; do
        [[ ! -f "$marker" ]] && continue
        plan_file=$(grep -E '^plan_file:' "$marker" | head -1 | sed 's/^plan_file:[[:space:]]*//')
        plan_file=$(normalize_plan_path "$plan_file")
        if [[ -n "$plan_file" && -f "$plan_file" ]]; then
            echo "$plan_file"
            return 0
        fi
    done

    return 1
}

resolve_plan_file() {
    local plan_file planning_started

    # 1) explicit persisted pointer (strongest)
    plan_file=$(normalize_plan_path "$(state_read plan_file)")
    if [[ -n "$plan_file" && -f "$plan_file" ]] && ! plan_is_done "$plan_file"; then
        echo "$plan_file"
        return 0
    fi

    # 2) active plan marker
    plan_file=$(active_plan_path_from_marker)
    if [[ -n "$plan_file" && -f "$plan_file" ]] && ! plan_is_done "$plan_file"; then
        echo "$plan_file"
        return 0
    fi

    # 3) planning window candidate (new plan created since EnterPlanMode)
    planning_started=$(state_read planning_started_at)
    if [[ "$planning_started" =~ ^[0-9]+$ && "$planning_started" -gt 0 ]]; then
        plan_file=$(newest_plan_file "$planning_started")
        if [[ -n "$plan_file" ]]; then
            echo "$plan_file"
            return 0
        fi
    fi

    # 4) last-resort newest plan
    plan_file=$(newest_plan_file 0)
    if [[ -n "$plan_file" ]]; then
        echo "$plan_file"
        return 0
    fi

    return 1
}

resolve_plan_file_for_manual_approve() {
    local plan_file planning_started

    # Prefer a plan created during the current planning window when available.
    planning_started=$(state_read planning_started_at)
    if [[ "$planning_started" =~ ^[0-9]+$ && "$planning_started" -gt 0 ]]; then
        plan_file=$(newest_plan_file "$planning_started")
        if [[ -n "$plan_file" ]]; then
            echo "$plan_file"
            return 0
        fi
    fi

    # Then use the newest plan on disk (authoritative for /approve).
    plan_file=$(newest_plan_file 0)
    if [[ -n "$plan_file" ]]; then
        echo "$plan_file"
        return 0
    fi

    # Fallback to active marker if no plan files are discoverable.
    plan_file=$(active_plan_path_from_marker)
    if [[ -n "$plan_file" && -f "$plan_file" ]]; then
        echo "$plan_file"
        return 0
    fi

    return 1
}

resolve_plan_file_for_exit_plan() {
    local plan_file planning_started

    # If planning is active, only trust plans written during this planning window.
    planning_started=$(state_read planning_started_at)
    if [[ "$planning_started" =~ ^[0-9]+$ && "$planning_started" -gt 0 ]]; then
        plan_file=$(newest_plan_file "$planning_started")
        if [[ -n "$plan_file" ]]; then
            echo "$plan_file"
            return 0
        fi
        return 1
    fi

    resolve_plan_file
}

plan_file_hash() {
    local plan_file="$1"
    shasum -a 256 "$plan_file" 2>/dev/null | awk '{print $1}'
}

extract_plan_objective() {
    local plan_file="$1"
    sed -n '/^##[[:space:]]*[Oo]bjective/,/^##/p' "$plan_file" \
        | tail -n +2 | grep -v '^## ' \
        | sed '/^[[:space:]]*$/d' \
        | head -3
}

extract_plan_scope() {
    local plan_file="$1"
    sed -n '/^##[[:space:]]*[Ss]cope/,/^##/p' "$plan_file" \
        | tail -n +2 | grep -v '^## ' \
        | grep -E '^\s*-\s+/' \
        | sed 's/^[[:space:]]*-[[:space:]]*//' \
        | sed 's/[[:space:]]*$//' \
        | sed 's/`//g' \
        | sed 's/ — .*//' \
        | sed 's/ - [A-Z].*//'
}

extract_plan_criteria() {
    local plan_file="$1"
    sed -n '/^##[[:space:]]*[Ss]uccess[[:space:]]*[Cc]riteria/,/^##/p' "$plan_file" \
        | tail -n +2 | grep -v '^## ' \
        | sed '/^[[:space:]]*$/d' \
        | head -3
}

write_active_plan_marker() {
    local plan_file="$1"
    local plan_hash="$2"
    local marker="${HOME}/.claude/.claude_active_plan"

    mkdir -p "${HOME}/.claude"
    cat > "$marker" <<EOF
plan_file: $plan_file
plan_hash: $plan_hash
approved_at: $(date -Iseconds)
project_hash: ${PROJECT_HASH}
EOF
}

write_approval_bundle() {
    local plan_file="$1"
    local plan_hash objective scope criteria

    [[ -z "$plan_file" || ! -f "$plan_file" ]] && return 1

    plan_hash=$(plan_file_hash "$plan_file")
    [[ -z "$plan_hash" ]] && return 1

    objective=$(extract_plan_objective "$plan_file")
    scope=$(extract_plan_scope "$plan_file")
    criteria=$(extract_plan_criteria "$plan_file")

    # Write metadata first; set approved marker last to avoid partial state.
    state_remove approved
    state_write plan_file "$plan_file"
    state_write plan_hash "$plan_hash"
    state_write objective "$objective"
    state_write scope "$scope"
    state_write criteria "$criteria"
    state_write approved "1"
    write_active_plan_marker "$plan_file" "$plan_hash" || true

    return 0
}

approval_bundle_is_complete() {
    local plan_file expected_hash current_hash scope_content

    state_exists approved || return 1
    state_exists plan_file || return 1
    state_exists plan_hash || return 1
    state_exists scope || return 1

    plan_file=$(normalize_plan_path "$(state_read plan_file)")
    [[ -n "$plan_file" && -f "$plan_file" ]] || return 1

    expected_hash=$(state_read plan_hash)
    [[ -n "$expected_hash" ]] || return 1

    current_hash=$(plan_file_hash "$plan_file")
    [[ "$current_hash" == "$expected_hash" ]] || return 1

    scope_content=$(state_read scope)
    [[ -n "$scope_content" ]] || return 1

    return 0
}

# ── Conversation token helpers (SEP-005) ──
resolve_memory_md() {
    local project_key
    project_key=$(pwd | tr '/' '-' | sed 's/^-//')
    echo "$HOME/.claude/projects/-${project_key}/memory/MEMORY.md"
}

generate_conversation_token() {
    local token mem_file mem_dir
    token=$(openssl rand -hex 8)

    # Write to persistent state
    state_write conversation_token "$token"

    # Write to MEMORY.md so it survives compaction
    mem_file=$(resolve_memory_md)
    mem_dir=$(dirname "$mem_file")
    mkdir -p "$mem_dir"

    if [[ -f "$mem_file" ]]; then
        # Remove existing Conversation Token section if present
        local tmp_file="${mem_file}.tmp.$$"
        awk '
            /^## Conversation Token/ { skip=1; next }
            /^## / && skip { skip=0 }
            !skip { print }
        ' "$mem_file" > "$tmp_file"
        mv "$tmp_file" "$mem_file"
    fi

    # Append token section
    printf '\n## Conversation Token\n`%s`\n' "$token" >> "$mem_file"

    echo "$token"
}

read_conversation_token() {
    local mem_file
    mem_file=$(resolve_memory_md)
    [[ -f "$mem_file" ]] || return 1
    sed -n '/^## Conversation Token/,/^## /{/^`/{s/^`//;s/`$//;p;q;};}' "$mem_file"
}

read_approval_token() {
    state_read approval_token
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
