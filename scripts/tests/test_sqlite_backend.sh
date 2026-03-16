#!/bin/bash
# test_sqlite_backend.sh — SQLite backend integration tests
# Tests the SQLite code path directly using a temporary database.
# Implements SEP-006.
# Usage: bash ~/.claude/scripts/tests/test_sqlite_backend.sh

set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASSED=0
FAILED=0
TOTAL=0
FAILURES=""
ORIGINAL_HOME="${HOME}"

source "${SCRIPTS_DIR}/common.sh"

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ── Test harness ──

setup() {
    TEST_TMPDIR=$(mktemp -d)
    export HOME="${TEST_TMPDIR}/home"
    WORKFLOW_DB="${HOME}/.claude/workflow.db"
    _DB_INITIALIZED=""
    CONV_ID=""
    SESSION_ID=""
    CONVERSATION_TOKEN=""
    mkdir -p "$HOME/.claude/plans" "$HOME/.claude"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
    _DB_INITIALIZED=""
    CONV_ID=""
    SESSION_ID=""
    CONVERSATION_TOKEN=""
    export HOME="${ORIGINAL_HOME}"
    WORKFLOW_DB="${HOME}/.claude/workflow.db"
}

# ── Test result tracking ──

current_test=""

begin_test() {
    current_test="$1"
    TOTAL=$(( TOTAL + 1 ))
}

pass() {
    PASSED=$(( PASSED + 1 ))
    printf "${GREEN}  PASS${NC} %s\n" "$current_test"
}

fail() {
    FAILED=$(( FAILED + 1 ))
    local reason="${1:-}"
    printf "${RED}  FAIL${NC} %s: %s\n" "$current_test" "$reason"
    FAILURES+="  - $current_test: $reason\n"
}

# ══════════════════════════════════════════════════════════════════
# GROUP 1: Database initialization
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 1: Database initialization ──${NC}\n"

begin_test "1.1 ensure_db creates tables"
setup
ensure_db
TABLES=$(sqlite3 "$WORKFLOW_DB" ".tables")
if echo "$TABLES" | grep -q "conversations" && \
   echo "$TABLES" | grep -q "sessions" && \
   echo "$TABLES" | grep -q "state" && \
   echo "$TABLES" | grep -q "events"; then
    pass
else
    fail "Missing tables (got: $TABLES)"
fi
teardown

begin_test "1.2 ensure_db sets WAL mode"
setup
ensure_db
MODE=$(sqlite3 "$WORKFLOW_DB" "PRAGMA journal_mode;")
if [[ "$MODE" == "wal" ]]; then
    pass
else
    fail "Expected WAL mode (got: $MODE)"
fi
teardown

begin_test "1.3 ensure_db is idempotent"
setup
ensure_db
_DB_INITIALIZED=""
ensure_db
TABLES=$(sqlite3 "$WORKFLOW_DB" ".tables")
if echo "$TABLES" | grep -q "conversations"; then
    pass
else
    fail "Tables missing after second ensure_db"
fi
teardown

# ══════════════════════════════════════════════════════════════════
# GROUP 2: Conversation identity resolution (init_persist_dir)
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 2: Conversation identity resolution ──${NC}\n"

begin_test "2.1 SESSION_ID found in sessions table → uses mapped CONV_ID"
setup
ensure_db
db_exec "INSERT INTO conversations (id, project_dir) VALUES ('conv-mapped', '$(pwd)');"
db_exec "INSERT INTO sessions (session_id, conversation_id) VALUES ('sess-known', 'conv-mapped');"
SESSION_ID="sess-known"
CONV_ID=""
init_persist_dir
if [[ "$CONV_ID" == "conv-mapped" ]]; then
    pass
else
    fail "Expected conv-mapped (got: $CONV_ID)"
fi
teardown

begin_test "2.2 SESSION_ID NOT in sessions table → uses SESSION_ID as CONV_ID"
setup
ensure_db
SESSION_ID="sess-new-123"
CONV_ID=""
init_persist_dir
if [[ "$CONV_ID" == "sess-new-123" ]]; then
    count=$(db_query "SELECT COUNT(*) FROM sessions WHERE session_id='sess-new-123';")
    if [[ "$count" == "1" ]]; then
        pass
    else
        fail "Session not registered in sessions table"
    fi
else
    fail "Expected sess-new-123 (got: $CONV_ID)"
fi
teardown

begin_test "2.3 No SESSION_ID, CONVERSATION_TOKEN env set → uses token as CONV_ID"
setup
ensure_db
SESSION_ID=""
CONV_ID=""
CONVERSATION_TOKEN="env-token-xyz"
init_persist_dir
if [[ "$CONV_ID" == "env-token-xyz" ]]; then
    pass
else
    fail "Expected env-token-xyz (got: $CONV_ID)"
fi
CONVERSATION_TOKEN=""
teardown

begin_test "2.4 No SESSION_ID, no env token, MEMORY.md token → reads and uses it"
setup
ensure_db
SESSION_ID=""
CONV_ID=""
CONVERSATION_TOKEN=""
PROJECT_KEY=$(pwd | tr '/' '-' | sed 's/^-//')
MEM_DIR="${HOME}/.claude/projects/-${PROJECT_KEY}/memory"
mkdir -p "$MEM_DIR"
cat > "${MEM_DIR}/MEMORY.md" <<'EOF'
# Memory

## Conversation Token
`mem-token-abc`
EOF
init_persist_dir
if [[ "$CONV_ID" == "mem-token-abc" ]]; then
    pass
else
    fail "Expected mem-token-abc (got: $CONV_ID)"
fi
teardown

begin_test "2.5 No SESSION_ID, no token → falls back to no-token"
setup
ensure_db
SESSION_ID=""
CONV_ID=""
CONVERSATION_TOKEN=""
init_persist_dir
if [[ "$CONV_ID" == "no-token" ]]; then
    pass
else
    fail "Expected no-token (got: $CONV_ID)"
fi
teardown

begin_test "2.6 last_active updated on resolution"
setup
ensure_db
db_exec "INSERT INTO conversations (id, project_dir, last_active) VALUES ('conv-stale', '$(pwd)', datetime('now', '-1 hour'));"
db_exec "INSERT INTO sessions (session_id, conversation_id) VALUES ('sess-stale', 'conv-stale');"
OLD_TIME=$(db_query "SELECT last_active FROM conversations WHERE id='conv-stale';")
sleep 1
SESSION_ID="sess-stale"
CONV_ID=""
init_persist_dir
NEW_TIME=$(db_query "SELECT last_active FROM conversations WHERE id='conv-stale';")
if [[ "$NEW_TIME" > "$OLD_TIME" ]]; then
    pass
else
    fail "last_active not updated (old: $OLD_TIME, new: $NEW_TIME)"
fi
teardown

# ══════════════════════════════════════════════════════════════════
# GROUP 3: State operations
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 3: State operations ──${NC}\n"

begin_test "3.1 state_write + state_read round-trip"
setup
ensure_db
CONV_ID="test-conv"
db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('$CONV_ID', '$(pwd)');"
state_write "test_key" "test_value"
RESULT=$(state_read "test_key")
if [[ "$RESULT" == "test_value" ]]; then
    pass
else
    fail "Expected test_value (got: $RESULT)"
fi
teardown

begin_test "3.2 state_exists true for written, false for missing"
setup
ensure_db
CONV_ID="test-conv"
db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('$CONV_ID', '$(pwd)');"
state_write "exists_key" "value"
EXISTS_OK=false
MISSING_OK=false
state_exists "exists_key" && EXISTS_OK=true
state_exists "missing_key" || MISSING_OK=true
if $EXISTS_OK && $MISSING_OK; then
    pass
else
    fail "exists=$EXISTS_OK, missing=$MISSING_OK"
fi
teardown

begin_test "3.3 state_remove deletes key"
setup
ensure_db
CONV_ID="test-conv"
db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('$CONV_ID', '$(pwd)');"
state_write "remove_key" "value"
state_remove "remove_key"
if ! state_exists "remove_key"; then
    pass
else
    fail "Key still exists after remove"
fi
teardown

begin_test "3.4 state_append appends with newline separator"
setup
ensure_db
CONV_ID="test-conv"
db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('$CONV_ID', '$(pwd)');"
state_write "append_key" "line1"
state_append "append_key" "line2"
RESULT=$(state_read "append_key")
EXPECTED=$'line1\nline2'
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass
else
    fail "Expected line1\\nline2 (got: $RESULT)"
fi
teardown

begin_test "3.5 state_append creates if missing"
setup
ensure_db
CONV_ID="test-conv"
db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('$CONV_ID', '$(pwd)');"
state_append "new_append" "first_line"
RESULT=$(state_read "new_append")
if [[ "$RESULT" == "first_line" ]]; then
    pass
else
    fail "Expected first_line (got: $RESULT)"
fi
teardown

begin_test "3.6 counter_increment starts at 1, increments atomically"
setup
ensure_db
CONV_ID="test-conv"
db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('$CONV_ID', '$(pwd)');"
V1=$(counter_increment "counter_key")
V2=$(counter_increment "counter_key")
V3=$(counter_increment "counter_key")
if [[ "$V1" == "1" && "$V2" == "2" && "$V3" == "3" ]]; then
    pass
else
    fail "Expected 1,2,3 (got: $V1,$V2,$V3)"
fi
teardown

begin_test "3.7 clear_all_state removes all keys for conversation"
setup
ensure_db
CONV_ID="test-conv"
db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('$CONV_ID', '$(pwd)');"
state_write "key1" "val1"
state_write "key2" "val2"
state_write "key3" "val3"
clear_all_state
REMAINING=$(db_query "SELECT COUNT(*) FROM state WHERE conversation_id='$CONV_ID';")
if [[ "$REMAINING" == "0" ]]; then
    pass
else
    fail "Expected 0 remaining (got: $REMAINING)"
fi
teardown

# ══════════════════════════════════════════════════════════════════
# GROUP 4: Conversation isolation
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 4: Conversation isolation ──${NC}\n"

begin_test "4.1 Two CONV_IDs writing same key → each reads own value"
setup
ensure_db
db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('conv-a', '$(pwd)');"
db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('conv-b', '$(pwd)');"
CONV_ID="conv-a"
state_write "shared_key" "value-a"
CONV_ID="conv-b"
state_write "shared_key" "value-b"
CONV_ID="conv-a"
VAL_A=$(state_read "shared_key")
CONV_ID="conv-b"
VAL_B=$(state_read "shared_key")
if [[ "$VAL_A" == "value-a" && "$VAL_B" == "value-b" ]]; then
    pass
else
    fail "Isolation broken (a=$VAL_A, b=$VAL_B)"
fi
teardown

begin_test "4.2 clear_all_state on A doesn't affect B"
setup
ensure_db
db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('conv-a', '$(pwd)');"
db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('conv-b', '$(pwd)');"
CONV_ID="conv-a"
state_write "key" "val-a"
CONV_ID="conv-b"
state_write "key" "val-b"
CONV_ID="conv-a"
clear_all_state
CONV_ID="conv-b"
VAL=$(state_read "key")
if [[ "$VAL" == "val-b" ]]; then
    pass
else
    fail "B's state was affected (got: $VAL)"
fi
teardown

# ══════════════════════════════════════════════════════════════════
# GROUP 5: Event logging
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 5: Event logging ──${NC}\n"

begin_test "5.1 log_event inserts with correct conversation_id and event_type"
setup
ensure_db
CONV_ID="test-conv"
SESSION_ID="test-sess"
db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('$CONV_ID', '$(pwd)');"
log_event "plan_approved" "test detail"
ROW=$(db_query "SELECT conversation_id, event_type, detail FROM events WHERE conversation_id='$CONV_ID' LIMIT 1;")
if [[ "$ROW" == "test-conv|plan_approved|test detail" ]]; then
    pass
else
    fail "Expected test-conv|plan_approved|test detail (got: $ROW)"
fi
teardown

# ══════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}═══ Results ═══${NC}\n"
printf "Total: %d  Passed: %d  Failed: %d\n" "$TOTAL" "$PASSED" "$FAILED"
if [[ $FAILED -gt 0 ]]; then
    printf "${RED}Failures:${NC}\n"
    printf "$FAILURES"
    exit 1
fi
printf "${GREEN}All tests passed.${NC}\n"
exit 0
