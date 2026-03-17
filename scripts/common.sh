#!/bin/bash
# common.sh — shared library for all Claude hook scripts
# Source this at the top of every hook: source "$(dirname "$0")/common.sh"
#
# Architecture: SQLite state backend (SEP-010, SEP-006).
# All state is stored in a SQLite database at ~/.claude/workflow.db.
# Tests override HOME to use a temporary database.
#
# The state_read/state_write/state_exists/state_remove API provides
# conversation-scoped key-value storage. Scripts should use these
# functions exclusively.

# ── Require jq ──
if ! command -v jq &>/dev/null; then
    echo "FATAL: jq is required but not found. Install with: brew install jq" >&2
    exit 1
fi

# ── SQLite helpers ──
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

CREATE TABLE IF NOT EXISTS plans (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id TEXT NOT NULL,
    file_path       TEXT,
    content         TEXT NOT NULL,
    hash            TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'draft',
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    approved_at     TEXT,
    completed_at    TEXT
);

CREATE INDEX IF NOT EXISTS idx_sessions_conv ON sessions(conversation_id);
CREATE INDEX IF NOT EXISTS idx_events_conv ON events(conversation_id);
CREATE INDEX IF NOT EXISTS idx_conv_project ON conversations(project_dir);
CREATE INDEX IF NOT EXISTS idx_plans_conv ON plans(conversation_id);
SQL
    _DB_INITIALIZED=1
}

# ── init_persist_dir: set up state backend ──
# SQLite conversation lookup/creation.
# If CONV_ID is already set (e.g. by test harness), skips identity resolution.
# Sets: PROJECT_HASH, PERSIST_DIR, CONVERSATION_TOKEN, CONV_ID
init_persist_dir() {
    ensure_db
    PROJECT_HASH=$(pwd | shasum | cut -c1-12)

    if [[ -z "${CONV_ID:-}" ]]; then
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
    else
        # CONV_ID pre-set — ensure conversation exists in DB
        db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('$(sql_escape "$CONV_ID")', '$(sql_escape "$(pwd)")');"
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
    if [[ -n "${CONVERSATION_TOKEN:-}" && "${CONVERSATION_TOKEN}" != "no-token" ]]; then
        echo "${HOME}/.claude/plans/${CONVERSATION_TOKEN}"
    else
        echo "${HOME}/.claude/plans"
    fi
}

# ── init_hook: read stdin, set up state backend ──
# Sets: HOOK_INPUT, SESSION_ID, PROJECT_HASH, PERSIST_DIR, CONV_ID
init_hook() {
    HOOK_INPUT=$(cat)

    SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null)

    if [[ -z "$SESSION_ID" && -z "${CONV_ID:-}" ]]; then
        echo '{"error":"BLOCKED: Hook system cannot verify session. SESSION_ID missing from hook input. Tool call denied (fail-closed)."}' >&2
        exit 1
    fi

    init_persist_dir
}

# ── State helpers (SQLite-backed) ──
state_file() {
    echo "${PERSIST_DIR}/$1"
}

state_exists() {
    local count
    count=$(db_query "SELECT COUNT(*) FROM state WHERE conversation_id='$(sql_escape "$CONV_ID")' AND key='$(sql_escape "$1")' AND value IS NOT NULL;")
    [[ "$count" -gt 0 ]]
}

state_write() {
    db_exec "INSERT OR REPLACE INTO state (conversation_id, key, value, updated_at) VALUES ('$(sql_escape "$CONV_ID")', '$(sql_escape "$1")', '$(sql_escape "$2")', datetime('now'));"
}

state_read() {
    db_query "SELECT value FROM state WHERE conversation_id='$(sql_escape "$CONV_ID")' AND key='$(sql_escape "$1")';"
}

state_remove() {
    db_exec "DELETE FROM state WHERE conversation_id='$(sql_escape "$CONV_ID")' AND key='$(sql_escape "$1")';"
}

state_append() {
    local key="$1" value="$2"
    local existing
    existing=$(db_query "SELECT COUNT(*) FROM state WHERE conversation_id='$(sql_escape "$CONV_ID")' AND key='$(sql_escape "$key")';")
    if [[ "$existing" -gt 0 ]]; then
        db_exec "UPDATE state SET value = value || char(10) || '$(sql_escape "$value")', updated_at = datetime('now') WHERE conversation_id='$(sql_escape "$CONV_ID")' AND key='$(sql_escape "$key")';"
    else
        state_write "$key" "$value"
    fi
}

clear_workflow_keys() {
    local keys=(
        approved plan_file plan_hash scope criteria
        objective_verification objective_verification_required
        planning planning_started_at
        dirty validated validation_log validated_unit validated_e2e
        tests_failed tests_reviewed
        objective_verified objective_verified_hash objective_verified_edit_count objective_verified_evidence
        validate_pending validate_pending_hash
        accept_bypass_pending accept_bypass_pending_hash
        user_bypass user_bypass_hash
        edit_count diagnostic_mode
    )
    local where_clause=""
    for key in "${keys[@]}"; do
        [[ -n "$where_clause" ]] && where_clause+=","
        where_clause+="'$(sql_escape "$key")'"
    done
    db_exec "DELETE FROM state WHERE conversation_id='$(sql_escape "$CONV_ID")' AND key IN ($where_clause);"
}

clear_plan_context_keys() {
    db_exec "DELETE FROM state WHERE conversation_id='$(sql_escape "$CONV_ID")' AND key IN ('objective','previous_objective','previous_plan_file');"
}

counter_increment() {
    local key="$1"
    db_exec "INSERT INTO state (conversation_id, key, value, updated_at) VALUES ('$(sql_escape "$CONV_ID")', '$(sql_escape "$key")', '1', datetime('now')) ON CONFLICT(conversation_id, key) DO UPDATE SET value = CAST(COALESCE(NULLIF(value, ''), '0') AS INTEGER) + 1, updated_at = datetime('now');"
    db_query "SELECT value FROM state WHERE conversation_id='$(sql_escape "$CONV_ID")' AND key='$(sql_escape "$key")';"
}

log_event() {
    local event_type="$1" detail="${2:-}"
    db_exec "INSERT INTO events (conversation_id, session_id, event_type, detail) VALUES ('$(sql_escape "${CONV_ID:-}")', '$(sql_escape "${SESSION_ID:-}")', '$(sql_escape "$event_type")', '$(sql_escape "$detail")');"
}

# ── Plan query helpers (plans table) ──
save_plan() {
    local file_path="$1" content="$2" status="$3"
    local hash
    hash=$(printf '%s' "$content" | shasum -a 256 | awk '{print $1}')
    local approved_at=""
    [[ "$status" == "approved" ]] && approved_at="datetime('now')"
    if [[ -n "$approved_at" ]]; then
        db_exec "INSERT INTO plans (conversation_id, file_path, content, hash, status, approved_at) VALUES ('$(sql_escape "$CONV_ID")', '$(sql_escape "$file_path")', '$(sql_escape "$content")', '$(sql_escape "$hash")', '$(sql_escape "$status")', datetime('now'));"
    else
        db_exec "INSERT INTO plans (conversation_id, file_path, content, hash, status) VALUES ('$(sql_escape "$CONV_ID")', '$(sql_escape "$file_path")', '$(sql_escape "$content")', '$(sql_escape "$hash")', '$(sql_escape "$status")');"
    fi
}

get_current_plan() {
    db_query "SELECT id, file_path, content, status FROM plans WHERE conversation_id='$(sql_escape "$CONV_ID")' AND status IN ('approved','draft') ORDER BY id DESC LIMIT 1;"
}

get_previous_plan() {
    db_query "SELECT id, file_path, content, status FROM plans WHERE conversation_id='$(sql_escape "$CONV_ID")' AND status IN ('approved','done') ORDER BY id DESC LIMIT 1;"
}

update_plan_status() {
    local plan_id="$1" new_status="$2"
    if [[ "$new_status" == "done" || "$new_status" == "rejected" ]]; then
        db_exec "UPDATE plans SET status='$(sql_escape "$new_status")', completed_at=datetime('now') WHERE id='$(sql_escape "$plan_id")';"
    else
        db_exec "UPDATE plans SET status='$(sql_escape "$new_status")' WHERE id='$(sql_escape "$plan_id")';"
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

resolve_plan_file() {
    local plan_file planning_started

    # 1) explicit persisted pointer (strongest)
    plan_file=$(normalize_plan_path "$(state_read plan_file)")
    if [[ -n "$plan_file" && -f "$plan_file" ]] && ! plan_is_done "$plan_file"; then
        echo "$plan_file"
        return 0
    fi

    # 2) plans table: most recent approved plan for this conversation
    local db_path
    db_path=$(db_query "SELECT file_path FROM plans WHERE conversation_id='$(sql_escape "$CONV_ID")' AND status='approved' ORDER BY id DESC LIMIT 1;")
    if [[ -n "$db_path" ]]; then
        db_path=$(normalize_plan_path "$db_path")
        if [[ -f "$db_path" ]] && ! plan_is_done "$db_path"; then
            echo "$db_path"
            return 0
        fi
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

    # 4) last-resort newest plan on disk
    plan_file=$(newest_plan_file 0)
    if [[ -n "$plan_file" ]]; then
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

    # Register as a conversation in SQLite
    ensure_db
    db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('$(sql_escape "$token")', '$(sql_escape "$(pwd)")');"

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
