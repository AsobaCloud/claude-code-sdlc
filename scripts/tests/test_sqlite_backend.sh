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

begin_test "2.2 SESSION_ID NOT in sessions table, no MEMORY.md token → uses SESSION_ID as CONV_ID"
setup
ensure_db
SESSION_ID="sess-new-123"
CONV_ID=""
CONVERSATION_TOKEN=""
# No MEMORY.md token exists — should fall back to SESSION_ID as CONV_ID
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

begin_test "2.2b SESSION_ID NOT in sessions table, MEMORY.md token exists → maps to MEMORY.md token"
setup
ensure_db
SESSION_ID="sess-compacted-456"
CONV_ID=""
CONVERSATION_TOKEN=""
# Write a MEMORY.md token (simulating a previous conversation that wrote it)
PROJECT_KEY=$(pwd | tr '/' '-' | sed 's/^-//')
MEM_DIR="${HOME}/.claude/projects/-${PROJECT_KEY}/memory"
mkdir -p "$MEM_DIR"
cat > "${MEM_DIR}/MEMORY.md" <<'EOF'
# Memory

## Conversation Token
`mem-token-xyz`
EOF
db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('mem-token-xyz', '$(pwd)');"
init_persist_dir
if [[ "$CONV_ID" == "mem-token-xyz" ]]; then
    # Verify the session is mapped to the MEMORY.md token conversation
    mapped_conv=$(db_query "SELECT conversation_id FROM sessions WHERE session_id='sess-compacted-456';")
    if [[ "$mapped_conv" == "mem-token-xyz" ]]; then
        pass
    else
        fail "Session mapped to wrong conversation (got: $mapped_conv)"
    fi
else
    fail "Expected mem-token-xyz (got: $CONV_ID)"
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

begin_test "2.7 Multiple sessions with same MEMORY.md token → all map to same CONV_ID"
setup
ensure_db
CONVERSATION_TOKEN=""
# Write a MEMORY.md token
PROJECT_KEY=$(pwd | tr '/' '-' | sed 's/^-//')
MEM_DIR="${HOME}/.claude/projects/-${PROJECT_KEY}/memory"
mkdir -p "$MEM_DIR"
cat > "${MEM_DIR}/MEMORY.md" <<'EOF'
# Memory

## Conversation Token
`shared-token-999`
EOF
db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('shared-token-999', '$(pwd)');"
# First session
SESSION_ID="sess-first"
CONV_ID=""
init_persist_dir
CONV1="$CONV_ID"
# Second session (simulates compaction — new session_id, same MEMORY.md token)
SESSION_ID="sess-second"
CONV_ID=""
_DB_INITIALIZED=""
init_persist_dir
CONV2="$CONV_ID"
# Third session
SESSION_ID="sess-third"
CONV_ID=""
_DB_INITIALIZED=""
init_persist_dir
CONV3="$CONV_ID"
if [[ "$CONV1" == "shared-token-999" && "$CONV2" == "shared-token-999" && "$CONV3" == "shared-token-999" ]]; then
    # Verify all three sessions are mapped to the same conversation
    count=$(db_query "SELECT COUNT(*) FROM sessions WHERE conversation_id='shared-token-999';")
    if [[ "$count" == "3" ]]; then
        pass
    else
        fail "Expected 3 sessions mapped (got: $count)"
    fi
else
    fail "Expected all shared-token-999 (got: $CONV1, $CONV2, $CONV3)"
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

begin_test "3.7 clear_workflow_keys removes workflow keys but not plan context keys"
setup
ensure_db
CONV_ID="test-conv"
db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('$CONV_ID', '$(pwd)');"
# Write workflow keys
state_write "approved" "1"
state_write "plan_file" "/tmp/plan.md"
state_write "plan_hash" "abc123"
state_write "dirty" "dirty"
state_write "validated" "npm test"
state_write "tests_failed" "red"
state_write "tests_reviewed" "1"
state_write "edit_count" "5"
# Write plan context keys (should survive)
state_write "objective" "Build the widget"
state_write "previous_objective" "Old task"
state_write "previous_plan_file" "/tmp/old-plan.md"
# Write non-workflow key (should survive)
state_write "last_sep_ref" "SEP-006"
clear_workflow_keys
# Workflow keys should be gone
WF_GONE=true
for key in approved plan_file plan_hash dirty validated tests_failed tests_reviewed edit_count; do
    if state_exists "$key"; then
        WF_GONE=false
        break
    fi
done
# Plan context keys should survive
CTX_OK=true
for key in objective previous_objective previous_plan_file; do
    if ! state_exists "$key"; then
        CTX_OK=false
        break
    fi
done
# Non-workflow key should survive
SEP_OK=true
if ! state_exists "last_sep_ref"; then
    SEP_OK=false
fi
if $WF_GONE && $CTX_OK && $SEP_OK; then
    pass
else
    fail "workflow_gone=$WF_GONE ctx_ok=$CTX_OK sep_ok=$SEP_OK"
fi
teardown

begin_test "3.8 clear_plan_context_keys removes context keys only"
setup
ensure_db
CONV_ID="test-conv"
db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('$CONV_ID', '$(pwd)');"
state_write "objective" "Build the widget"
state_write "previous_objective" "Old task"
state_write "previous_plan_file" "/tmp/old-plan.md"
state_write "last_sep_ref" "SEP-006"
state_write "approved" "1"
clear_plan_context_keys
# Context keys should be gone
CTX_GONE=true
for key in objective previous_objective previous_plan_file; do
    if state_exists "$key"; then
        CTX_GONE=false
        break
    fi
done
# Other keys should survive
OTHERS_OK=true
if ! state_exists "last_sep_ref" || ! state_exists "approved"; then
    OTHERS_OK=false
fi
if $CTX_GONE && $OTHERS_OK; then
    pass
else
    fail "ctx_gone=$CTX_GONE others_ok=$OTHERS_OK"
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

begin_test "4.2 clear_workflow_keys on A doesn't affect B"
setup
ensure_db
db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('conv-a', '$(pwd)');"
db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('conv-b', '$(pwd)');"
CONV_ID="conv-a"
state_write "approved" "1"
state_write "dirty" "dirty-a"
CONV_ID="conv-b"
state_write "approved" "1"
state_write "dirty" "dirty-b"
CONV_ID="conv-a"
clear_workflow_keys
CONV_ID="conv-b"
VAL=$(state_read "approved")
DIRTY=$(state_read "dirty")
if [[ "$VAL" == "1" && "$DIRTY" == "dirty-b" ]]; then
    pass
else
    fail "B's state was affected (approved=$VAL, dirty=$DIRTY)"
fi
teardown

# ══════════════════════════════════════════════════════════════════
# GROUP 4b: Plans table operations
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 4b: Plans table operations ──${NC}\n"

begin_test "4b.1 save_plan + get_current_plan round-trip"
setup
ensure_db
CONV_ID="test-conv"
db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('$CONV_ID', '$(pwd)');"
save_plan "/tmp/my-plan.md" "# Plan content here" "approved"
RESULT=$(get_current_plan)
PLAN_PATH=$(echo "$RESULT" | cut -d'|' -f2)
PLAN_CONTENT=$(echo "$RESULT" | cut -d'|' -f3)
PLAN_STATUS=$(echo "$RESULT" | cut -d'|' -f4)
if [[ "$PLAN_PATH" == "/tmp/my-plan.md" && "$PLAN_CONTENT" == "# Plan content here" && "$PLAN_STATUS" == "approved" ]]; then
    pass
else
    fail "Round-trip failed (path=$PLAN_PATH, status=$PLAN_STATUS)"
fi
teardown

begin_test "4b.2 get_previous_plan returns last approved/done plan, not draft"
setup
ensure_db
CONV_ID="test-conv"
db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('$CONV_ID', '$(pwd)');"
save_plan "/tmp/old-plan.md" "Old plan" "done"
save_plan "/tmp/draft-plan.md" "Draft plan" "draft"
RESULT=$(get_previous_plan)
PLAN_PATH=$(echo "$RESULT" | cut -d'|' -f2)
PLAN_STATUS=$(echo "$RESULT" | cut -d'|' -f4)
if [[ "$PLAN_PATH" == "/tmp/old-plan.md" && "$PLAN_STATUS" == "done" ]]; then
    pass
else
    fail "Expected old-plan.md/done (got path=$PLAN_PATH, status=$PLAN_STATUS)"
fi
teardown

begin_test "4b.3 update_plan_status changes status and sets completed_at"
setup
ensure_db
CONV_ID="test-conv"
db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('$CONV_ID', '$(pwd)');"
save_plan "/tmp/plan.md" "Content" "approved"
PLAN_ID=$(db_query "SELECT id FROM plans WHERE conversation_id='$CONV_ID' ORDER BY id DESC LIMIT 1;")
update_plan_status "$PLAN_ID" "done"
ROW=$(db_query "SELECT status, completed_at IS NOT NULL FROM plans WHERE id='$PLAN_ID';")
if [[ "$ROW" == "done|1" ]]; then
    pass
else
    fail "Expected done|1 (got: $ROW)"
fi
teardown

begin_test "4b.4 get_current_plan returns most recent approved plan"
setup
ensure_db
CONV_ID="test-conv"
db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('$CONV_ID', '$(pwd)');"
save_plan "/tmp/plan-1.md" "First plan" "approved"
save_plan "/tmp/plan-2.md" "Second plan" "approved"
RESULT=$(get_current_plan)
PLAN_PATH=$(echo "$RESULT" | cut -d'|' -f2)
if [[ "$PLAN_PATH" == "/tmp/plan-2.md" ]]; then
    pass
else
    fail "Expected plan-2.md (got: $PLAN_PATH)"
fi
teardown

begin_test "4b.5 plans table is conversation-scoped"
setup
ensure_db
db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('conv-a', '$(pwd)');"
db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('conv-b', '$(pwd)');"
CONV_ID="conv-a"
save_plan "/tmp/plan-a.md" "Plan A" "approved"
CONV_ID="conv-b"
RESULT=$(get_current_plan)
if [[ -z "$RESULT" ]]; then
    pass
else
    fail "conv-b saw conv-a's plan (got: $RESULT)"
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
# GROUP 6: Conditional token generation on SessionStart (SEP-012)
# ══════════════════════════════════════════════════════════════════
printf "\n${YELLOW}── Group 6: Conditional token generation on SessionStart (SEP-012) ──${NC}\n"

# Helper: write a token to MEMORY.md in the test HOME
write_memory_token() {
    local token="$1"
    local mem_file
    mem_file=$(resolve_memory_md)
    mkdir -p "$(dirname "$mem_file")"
    printf '\n## Conversation Token\n`%s`\n' "$token" >> "$mem_file"
}

# 6.1 SessionStart preserves existing MEMORY.md token
begin_test "6.1 cleanup_stale_sessions.sh preserves existing MEMORY.md token"
setup
ensure_db
write_memory_token "old-token-aaa"
db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('old-token-aaa', '$(pwd)');"
# Run the actual script
bash "${SCRIPTS_DIR}/cleanup_stale_sessions.sh" 2>/dev/null || true
RESULT=$(read_conversation_token 2>/dev/null) || true
if [[ "$RESULT" == "old-token-aaa" ]]; then
    pass
else
    fail "Expected old-token-aaa (got: $RESULT)"
fi
teardown

# 6.2 SessionStart generates token when MEMORY.md has none
begin_test "6.2 cleanup_stale_sessions.sh generates token when MEMORY.md has none"
setup
ensure_db
# MEMORY.md exists but has no token section
mem_file=$(resolve_memory_md)
mkdir -p "$(dirname "$mem_file")"
echo "# Memory" > "$mem_file"
bash "${SCRIPTS_DIR}/cleanup_stale_sessions.sh" 2>/dev/null || true
RESULT=$(read_conversation_token 2>/dev/null) || true
if [[ -n "$RESULT" && ${#RESULT} -eq 16 ]]; then
    pass
else
    fail "Expected 16-char hex token (got: '$RESULT')"
fi
teardown

# 6.3 SessionStart refreshes last_active for existing token
begin_test "6.3 cleanup_stale_sessions.sh refreshes last_active for existing token"
setup
ensure_db
write_memory_token "stale-token-bbb"
db_exec "INSERT INTO conversations (id, project_dir, last_active) VALUES ('stale-token-bbb', '$(pwd)', datetime('now', '-5 days'));"
bash "${SCRIPTS_DIR}/cleanup_stale_sessions.sh" 2>/dev/null || true
RECENT=$(db_query "SELECT CASE WHEN last_active > datetime('now', '-1 minute') THEN 'yes' ELSE 'no' END FROM conversations WHERE id='stale-token-bbb';")
if [[ "$RECENT" == "yes" ]]; then
    pass
else
    LAST_ACTIVE=$(db_query "SELECT last_active FROM conversations WHERE id='stale-token-bbb';")
    fail "Expected last_active refreshed (got: $LAST_ACTIVE)"
fi
teardown

# 6.4 Standalone script finds state after session restart via cleanup_stale_sessions.sh
begin_test "6.4 Standalone script finds state after session restart"
setup
ensure_db
write_memory_token "persist-token-ccc"
db_exec "INSERT OR IGNORE INTO conversations (id, project_dir) VALUES ('persist-token-ccc', '$(pwd)');"
CONV_ID="persist-token-ccc"
state_write approved "1"
state_write plan_hash "test-hash"
state_write scope "/tmp/test.txt"
state_write objective "Test objective"
state_write criteria "Test criteria"
state_write plan_file "/tmp/test-plan.md"
state_write objective_verification_required "1"
# Simulate session restart by running the actual script
bash "${SCRIPTS_DIR}/cleanup_stale_sessions.sh" 2>/dev/null || true
# Clear identity (simulating standalone script environment)
CONV_ID=""
SESSION_ID=""
CONVERSATION_TOKEN=""
_DB_INITIALIZED=""
# Re-resolve via init_persist_dir (like restore_approval.sh would)
init_persist_dir
if [[ "$CONV_ID" == "persist-token-ccc" ]]; then
    APPROVED_VAL=$(state_read approved)
    if [[ "$APPROVED_VAL" == "1" ]]; then
        pass
    else
        fail "CONV_ID correct but approved state lost (got: '$APPROVED_VAL')"
    fi
else
    fail "Expected CONV_ID=persist-token-ccc (got: $CONV_ID)"
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
