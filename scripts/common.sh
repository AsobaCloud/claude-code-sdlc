#!/bin/bash
# common.sh — shared library for all Claude hook scripts
# Source this at the top of every hook: source "$(dirname "$0")/common.sh"
#
# Architecture: Dual-mode state backend (SEP-010).
# - Test mode (CLAUDE_TEST_PERSIST_DIR set): flat files in temp directory
# - Production mode: SQLite database at ~/.claude/workflow.db
#
# The state_read/state_write/state_exists/state_remove API is identical
# in both modes. Scripts should use these functions exclusively.

# ── Require jq ──
if ! command -v jq &>/dev/null; then
    echo "FATAL: jq is required but not found. Install with: brew install jq" >&2
    exit 1
fi

# ── Mode detection ──
_is_test_mode() { [[ -n "${CLAUDE_TEST_PERSIST_DIR:-}" ]]; }

# ── SQLite helpers (production only) ──
WORKFLOW_DB="${HOME}/.claude/workflow.db"

sql_escape() {
    printf '%s' "${1//\'/\'\'}"
}

db_exec() {
    sqlite3 "$WORKFLOW_DB" "$1"
}

db_query() {
    sqlite3 "$WORKFLOW_DB" "$1"
}

ensure_db() {
    [[ -n "${_DB_INITIALIZED:-}" ]] && return 0
    mkdir -p "$(dirname "$WORKFLOW_DB")"
    sqlite3 "$WORKFLOW_DB" <<'SQL' >/dev/null
PRAGMA journal_mode=WAL;

CREATE TABLE IF NOT EXISTS conversations (
    id              TEXT PRIMARY KEY,
    project_dir     TEXT NOT NULL,
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    last_active     TEXT NOT NULL DEFAULT (datetime('now')),
    phase           TEXT NOT NULL DEFAULT 'idle'
);

CREATE TABLE IF NOT EXISTS sessions (
    session_id      TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL REFERENCES conversations(id),
    started_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS state (
    conversation_id TEXT NOT NULL,
    key             TEXT NOT NULL,
    value           TEXT,
    updated_at      TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (conversation_id, key)
);

CREATE TABLE IF NOT EXISTS events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id TEXT NOT NULL,
    session_id      TEXT,
    timestamp       TEXT NOT NULL DEFAULT (datetime('now')),
    event_type      TEXT NOT NULL,
    detail          TEXT
);

CREATE INDEX IF NOT EXISTS idx_sessions_conv ON sessions(conversation_id);
CREATE INDEX IF NOT EXISTS idx_events_conv ON events(conversation_id);
CREATE INDEX IF NOT EXISTS idx_conv_project ON conversations(project_dir);
SQL
    _DB_INITIALIZED=1
}

# ── init_persist_dir: set up state backend ──
# Test mode: flat files in CLAUDE_TEST_PERSIST_DIR (unchanged)
# Production: SQLite conversation lookup/creation
# Sets: PROJECT_HASH, PERSIST_DIR, CONVERSATION_TOKEN, CONV_ID (production only)
init_persist_dir() {
    if _is_test_mode; then
        PROJECT_HASH="test"
        PERSIST_DIR="$CLAUDE_TEST_PERSIST_DIR"
        CONVERSATION_TOKEN="${CONVERSATION_TOKEN:-}"
        mkdir -p "$PERSIST_DIR"
        mkdir -p "$(conversation_plan_dir)"
        return
    fi

    # Production: SQLite-backed
    ensure_db
    PROJECT_HASH=$(pwd | shasum | cut -c1-12)
    CONV_ID=""

    # 1) SESSION_ID → sessions table lookup
    if [[ -n "${SESSION_ID:-}" ]]; then
        CONV_ID=$(db_query "SELECT conversation_id FROM sessions WHERE session_id='$(sql_escape "$SESSION_ID")';")
        # If session not found, use SESSION_ID as the conversation identity
        if [[ -z "$CONV_ID" ]]; then
            CONV_ID="$SESSION_ID"
            db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('$(sql_escape "$CONV_ID")', '$(sql_escape "$(pwd)")');"
            db_exec "INSERT OR IGNORE INTO sessions (session_id, conversation_id) VALUES ('$(sql_escape "$SESSION_ID")', '$(sql_escape "$CONV_ID")');"
        fi
    fi

    # 2) CONVERSATION_TOKEN env or MEMORY.md → use as conversation ID
    if [[ -z "$CONV_ID" ]]; then
        local token="${CONVERSATION_TOKEN:-}"
        if [[ -z "$token" ]]; then
            token=$(read_conversation_token 2>/dev/null) || true
        fi
        if [[ -n "$token" ]]; then
            db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('$(sql_escape "$token")', '$(sql_escape "$(pwd)")');"
            CONV_ID="$token"
        fi
    fi

    # 3) No token available → use "no-token" fallback
    if [[ -z "$CONV_ID" ]]; then
        CONV_ID="no-token"
        db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('$(sql_escape "$CONV_ID")', '$(sql_escape "$(pwd)")');"
    fi

    # Register session → conversation mapping (if not done above)
    if [[ -n "${SESSION_ID:-}" ]]; then
        db_exec "INSERT OR IGNORE INTO sessions (session_id, conversation_id) VALUES ('$(sql_escape "$SESSION_ID")', '$(sql_escape "$CONV_ID")');"
    fi

    # Update activity timestamp
    db_exec "UPDATE conversations SET last_active = datetime('now') WHERE id='$(sql_escape "$CONV_ID")';"

    # Set globals for backward compat
    CONVERSATION_TOKEN="$CONV_ID"
    PERSIST_DIR="${HOME}/.claude/state/${PROJECT_HASH}/${CONVERSATION_TOKEN}"
    mkdir -p "$PERSIST_DIR"
    mkdir -p "$(conversation_plan_dir)"
}

# ── Conversation-scoped plan directory ──
conversation_plan_dir() {
    if [[ -n "${CLAUDE_TEST_PERSIST_DIR:-}" ]]; then
        echo "${HOME}/.claude/plans"
    elif [[ -n "${CONVERSATION_TOKEN:-}" && "${CONVERSATION_TOKEN}" != "no-token" ]]; then
        echo "${HOME}/.claude/plans/${CONVERSATION_TOKEN}"
    else
        echo "${HOME}/.claude/plans"
    fi
}

# ── init_hook: read stdin, set up state backend ──
# Sets: HOOK_INPUT, SESSION_ID, PROJECT_HASH, PERSIST_DIR, CONV_ID (production)
init_hook() {
    HOOK_INPUT=$(cat)

    SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null)

    if [[ -z "$SESSION_ID" && -z "$CLAUDE_TEST_PERSIST_DIR" ]]; then
        exit 0
    fi

    init_persist_dir
}

# ── State helpers (dual-mode: flat files in test, SQLite in production) ──
state_file() {
    echo "${PERSIST_DIR}/$1"
}

state_exists() {
    if _is_test_mode; then
        [[ -f "${PERSIST_DIR}/$1" ]]
    else
        local count
        count=$(db_query "SELECT COUNT(*) FROM state WHERE conversation_id='$(sql_escape "$CONV_ID")' AND key='$(sql_escape "$1")' AND value IS NOT NULL;")
        [[ "$count" -gt 0 ]]
    fi
}

state_write() {
    if _is_test_mode; then
        echo "$2" > "${PERSIST_DIR}/$1"
    else
        db_exec "INSERT OR REPLACE INTO state (conversation_id, key, value, updated_at) VALUES ('$(sql_escape "$CONV_ID")', '$(sql_escape "$1")', '$(sql_escape "$2")', datetime('now'));"
    fi
}

state_read() {
    if _is_test_mode; then
        cat "${PERSIST_DIR}/$1" 2>/dev/null || true
    else
        db_query "SELECT value FROM state WHERE conversation_id='$(sql_escape "$CONV_ID")' AND key='$(sql_escape "$1")';"
    fi
}

state_remove() {
    if _is_test_mode; then
        rm -f "${PERSIST_DIR}/$1"
    else
        db_exec "DELETE FROM state WHERE conversation_id='$(sql_escape "$CONV_ID")' AND key='$(sql_escape "$1")';"
    fi
}

state_append() {
    local key="$1" value="$2"
    if _is_test_mode; then
        echo "$value" >> "${PERSIST_DIR}/$key"
    else
        local existing
        existing=$(db_query "SELECT COUNT(*) FROM state WHERE conversation_id='$(sql_escape "$CONV_ID")' AND key='$(sql_escape "$key")';")
        if [[ "$existing" -gt 0 ]]; then
            db_exec "UPDATE state SET value = value || char(10) || '$(sql_escape "$value")', updated_at = datetime('now') WHERE conversation_id='$(sql_escape "$CONV_ID")' AND key='$(sql_escape "$key")';"
        else
            state_write "$key" "$value"
        fi
    fi
}

clear_all_state() {
    if _is_test_mode; then
        rm -f \
            "${PERSIST_DIR}/approved" \
            "${PERSIST_DIR}/objective" \
            "${PERSIST_DIR}/scope" \
            "${PERSIST_DIR}/criteria" \
            "${PERSIST_DIR}/objective_verification" \
            "${PERSIST_DIR}/objective_verification_required" \
            "${PERSIST_DIR}/plan_file" \
            "${PERSIST_DIR}/plan_hash" \
            "${PERSIST_DIR}/planning" \
            "${PERSIST_DIR}/planning_started_at" \
            "${PERSIST_DIR}/diagnostic_mode" \
            "${PERSIST_DIR}/dirty" \
            "${PERSIST_DIR}/validated" \
            "${PERSIST_DIR}/validation_log" \
            "${PERSIST_DIR}/validated_unit" \
            "${PERSIST_DIR}/validated_e2e" \
            "${PERSIST_DIR}/tests_failed" \
            "${PERSIST_DIR}/tests_reviewed" \
            "${PERSIST_DIR}/objective_verified" \
            "${PERSIST_DIR}/objective_verified_hash" \
            "${PERSIST_DIR}/objective_verified_edit_count" \
            "${PERSIST_DIR}/objective_verified_evidence" \
            "${PERSIST_DIR}/validate_pending" \
            "${PERSIST_DIR}/validate_pending_hash" \
            "${PERSIST_DIR}/accept_bypass_pending" \
            "${PERSIST_DIR}/accept_bypass_pending_hash" \
            "${PERSIST_DIR}/user_bypass" \
            "${PERSIST_DIR}/user_bypass_hash" \
            "${PERSIST_DIR}/edit_count"
    else
        db_exec "DELETE FROM state WHERE conversation_id='$(sql_escape "$CONV_ID")';"
    fi
}

counter_increment() {
    local key="$1"
    if _is_test_mode; then
        local value=0
        if state_exists "$key"; then
            value=$(state_read "$key")
        fi
        [[ "$value" =~ ^[0-9]+$ ]] || value=0
        value=$(( value + 1 ))
        state_write "$key" "$value"
        echo "$value"
    else
        db_exec "INSERT INTO state (conversation_id, key, value, updated_at) VALUES ('$(sql_escape "$CONV_ID")', '$(sql_escape "$key")', '1', datetime('now')) ON CONFLICT(conversation_id, key) DO UPDATE SET value = CAST(COALESCE(NULLIF(value, ''), '0') AS INTEGER) + 1, updated_at = datetime('now');"
        db_query "SELECT value FROM state WHERE conversation_id='$(sql_escape "$CONV_ID")' AND key='$(sql_escape "$key")';"
    fi
}

log_event() {
    local event_type="$1" detail="${2:-}"
    if ! _is_test_mode; then
        db_exec "INSERT INTO events (conversation_id, session_id, event_type, detail) VALUES ('$(sql_escape "${CONV_ID:-}")', '$(sql_escape "${SESSION_ID:-}")', '$(sql_escape "$event_type")', '$(sql_escape "$detail")');"
    fi
}

# Legacy aliases — scripts that call persist_* still work
persist_file() { state_file "$@"; }
persist_exists() { state_exists "$@"; }
persist_write() { state_write "$@"; }
persist_read() { state_read "$@"; }
persist_remove() { state_remove "$@"; }

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

    for dir in "$(conversation_plan_dir)" ".claude/plans"; do
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

    # 1) Check existing plan_file state marker first (set by previous approval).
    # When /approve is called in a new conversation, this marker points to the
    # correct plan from the previous session — don't override with mtime guess.
    plan_file=$(normalize_plan_path "$(state_read plan_file)")
    if [[ -n "$plan_file" && -f "$plan_file" ]] && ! plan_is_done "$plan_file"; then
        echo "$plan_file"
        return 0
    fi

    # 2) Prefer a plan created during the current planning window when available.
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

extract_plan_objective_verification() {
    local plan_file="$1"
    sed -n '/^##[[:space:]]*[Oo]bjective[[:space:]]*[Vv]erification/,/^##/p' "$plan_file" \
        | tail -n +2 | grep -v '^## ' \
        | sed '/^[[:space:]]*$/d'
}

plan_requires_objective_verification() {
    local plan_file="$1"
    local scope_path=""

    while IFS= read -r scope_path; do
        [[ -z "$scope_path" ]] && continue
        [[ "$scope_path" == *"/.claude/plans/"* ]] && continue
        [[ "$scope_path" == *"/.sep/"* ]] && continue
        [[ "$scope_path" == *"/.claude/projects/"*"/memory/"* ]] && continue
        if [[ ! "$scope_path" =~ \.(md|mdx|txt|rst)$ ]]; then
            return 0
        fi
    done <<< "$(extract_plan_scope "$plan_file")"

    return 1
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
    local plan_hash objective scope criteria objective_verification objective_verification_required

    [[ -z "$plan_file" || ! -f "$plan_file" ]] && return 1

    plan_hash=$(plan_file_hash "$plan_file")
    [[ -z "$plan_hash" ]] && return 1

    objective=$(extract_plan_objective "$plan_file")
    scope=$(extract_plan_scope "$plan_file")
    criteria=$(extract_plan_criteria "$plan_file")
    objective_verification=$(extract_plan_objective_verification "$plan_file")
    if plan_requires_objective_verification "$plan_file"; then
        objective_verification_required="1"
    else
        objective_verification_required="0"
    fi

    # Write metadata first; set approved marker last to avoid partial state.
    state_remove approved
    state_write plan_file "$plan_file"
    state_write plan_hash "$plan_hash"
    state_write objective "$objective"
    state_write scope "$scope"
    state_write criteria "$criteria"
    state_write objective_verification_required "$objective_verification_required"
    state_write objective_verification "$objective_verification"
    state_write approved "1"
    write_active_plan_marker "$plan_file" "$plan_hash" || true

    return 0
}

approval_bundle_is_complete() {
    local plan_file expected_hash current_hash scope_content objective_verification_required

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

    objective_verification_required=$(state_read objective_verification_required)
    [[ -n "$objective_verification_required" ]] || return 1
    if [[ "$objective_verification_required" == "1" ]]; then
        [[ -n "$(state_read objective_verification)" ]] || return 1
    fi

    return 0
}

current_plan_hash() {
    state_read plan_hash
}

current_edit_count() {
    local count
    count=$(state_read edit_count)
    if [[ "$count" =~ ^[0-9]+$ ]]; then
        echo "$count"
    else
        echo "0"
    fi
}

objective_verification_required_for_current_plan() {
    [[ "$(state_read objective_verification_required)" == "1" ]]
}

objective_verified_for_current_plan() {
    local current_hash verified_hash verified_edit_count current_edit_count_value
    current_hash=$(current_plan_hash)
    verified_hash=$(state_read objective_verified_hash)
    verified_edit_count=$(state_read objective_verified_edit_count)
    current_edit_count_value=$(current_edit_count)

    [[ -n "$current_hash" ]] || return 1
    [[ -n "$verified_hash" ]] || return 1
    state_exists objective_verified || return 1
    [[ "$current_hash" == "$verified_hash" ]] || return 1
    [[ "$verified_edit_count" == "$current_edit_count_value" ]]
}

validate_pending_for_current_plan() {
    local current_hash pending_hash
    current_hash=$(current_plan_hash)
    pending_hash=$(state_read validate_pending_hash)

    [[ -n "$current_hash" ]] || return 1
    [[ -n "$pending_hash" ]] || return 1
    state_exists validate_pending || return 1
    [[ "$current_hash" == "$pending_hash" ]]
}

accept_bypass_pending_for_current_plan() {
    local current_hash pending_hash
    current_hash=$(current_plan_hash)
    pending_hash=$(state_read accept_bypass_pending_hash)

    [[ -n "$current_hash" ]] || return 1
    [[ -n "$pending_hash" ]] || return 1
    state_exists accept_bypass_pending || return 1
    [[ "$current_hash" == "$pending_hash" ]]
}

user_bypass_for_current_plan() {
    local current_hash bypass_hash
    current_hash=$(current_plan_hash)
    bypass_hash=$(state_read user_bypass_hash)

    [[ -n "$current_hash" ]] || return 1
    [[ -n "$bypass_hash" ]] || return 1
    state_exists user_bypass || return 1
    [[ "$current_hash" == "$bypass_hash" ]]
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

    # In production mode, also register as a conversation in SQLite
    if ! _is_test_mode; then
        ensure_db
        db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('$(sql_escape "$token")', '$(sql_escape "$(pwd)")');"
    fi

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
