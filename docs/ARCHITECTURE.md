# Hook System Architecture Contract

This is the single authoritative contract for the Claude Code hook system. It describes the CORRECT DESIGN — how the system MUST work. Where the implementation doesn't yet match, a `⚠ NOT YET IMPLEMENTED` note flags the gap, but the contract itself specifies correct behavior.

All future changes to the hook system MUST reference this document. Any change that violates a stated invariant requires updating this contract FIRST.

---

## 1. System Purpose

This hook system enforces epistemic discipline in Claude Code workflows. It prevents the model from editing code without an approved plan, ensures test-driven implementation order, enforces scope boundaries, and maintains workflow state across context compaction. The system exists because the model will otherwise skip planning, drift from approved scope, and lose awareness of its own workflow state.

---

## 2. Lifecycle State Machine

### Primary workflow (code changes)

```
IDLE
  │ User calls EnterPlanMode
  ▼
PLANNING
  │ Model writes plan file, calls ExitPlanMode
  │ Hook validates plan quality
  ▼
APPROVED
  │ Model writes test files (always allowed)
  │ Runs tests → must fail (red phase)
  ▼
TESTS_WRITTEN
  │ User reviews tests: /approve-tests or /skip-tests
  ▼
IMPLEMENTING
  │ Model edits production code (scope-enforced)
  │ Each edit sets dirty flag, increments edit_count
  ▼
VALIDATING
  │ Run unit tests (sets validated_unit)
  │ Run E2E tests (sets validated_e2e)
  │ Both must pass → dirty clears
  ▼
VERIFIED
  │ Run objective verification command
  │ Record with record_validation.sh --command
  ▼
COMPLETED
  │ clear_approval.sh → user /accept or /reject
  ▼
IDLE
```

### Investigation workflow (diagnostic questions)

```
IDLE
  │ User asks diagnostic question
  ▼
DIAGNOSTIC (phase 1: blocked as speed bump)
  │ User re-submits
  ▼
INVESTIGATION_PLANNING
  │ Model writes investigation plan with ## Hypothesis
  │ ExitPlanMode → relaxed validation
  ▼
INVESTIGATING
  │ Tools unlocked, model investigates
  │ Presents findings with evidence
  ▼
COMPLETED
```

### Recovery paths

| Command | From state | Effect |
|---|---|---|
| `/approve` | Any | Rebuilds approval bundle from newest plan |
| `/reject` | IMPLEMENTING+ | Clears all state, forces re-planning |
| `/skip-tests` | TESTS_WRITTEN | Bypasses TDD gate entirely |
| `/skip-investigation` | DIAGNOSTIC | Exits investigation mode |
| `/accept` (twice) | VERIFIED (no proof) | User bypass of objective verification |

---

## 3. State Storage Contract

### Dual-mode backend (SEP-010)

State storage uses a dual-mode backend in `common.sh`:

- **Test mode** (`CLAUDE_TEST_PERSIST_DIR` set): Flat files in temp directory — preserves backward compatibility with the entire test suite.
- **Production mode**: SQLite database at `~/.claude/workflow.db` — eliminates path assembly bugs, silent failures, and non-atomic writes.

The `state_read()`/`state_write()`/`state_exists()`/`state_remove()` API is identical in both modes. Scripts use these functions exclusively.

### SQLite schema (`~/.claude/workflow.db`)

```sql
PRAGMA journal_mode=WAL;

CREATE TABLE conversations (
    id              TEXT PRIMARY KEY,     -- conversation token (hex)
    project_dir     TEXT NOT NULL,        -- absolute path to project
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    last_active     TEXT NOT NULL DEFAULT (datetime('now')),
    phase           TEXT NOT NULL DEFAULT 'idle'
);

CREATE TABLE sessions (
    session_id      TEXT PRIMARY KEY,     -- from Claude Code hook JSON
    conversation_id TEXT NOT NULL REFERENCES conversations(id),
    started_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE state (
    conversation_id TEXT NOT NULL,
    key             TEXT NOT NULL,        -- same keys as the old flat files
    value           TEXT,
    updated_at      TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (conversation_id, key)
);

CREATE TABLE events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id TEXT NOT NULL,
    session_id      TEXT,
    timestamp       TEXT NOT NULL DEFAULT (datetime('now')),
    event_type      TEXT NOT NULL,
    detail          TEXT
);
```

### State keys (same in both modes)

| Key | Value | Description |
|---|---|---|
| `approved` | `"1"` | Plan is approved |
| `plan_file` | absolute path | Approved plan file |
| `plan_hash` | SHA256 hex | Plan hash at approval time |
| `objective` | text | Extracted from ## Objective |
| `scope` | newline-separated paths | Extracted from ## Scope |
| `criteria` | text | Extracted from ## Success Criteria |
| `objective_verification` | text | Extracted from ## Objective Verification |
| `objective_verification_required` | `"0"` or `"1"` | Whether plan requires verification |
| `planning` | `"1"` | Plan mode active |
| `planning_started_at` | epoch seconds | When plan mode entered |
| `edit_count` | decimal | Counter incremented per edit |
| `dirty` | `"timestamp path"` | Unvalidated edits exist |
| `validated` | command | Last validation command |
| `validation_log` | multi-line | Append-only validation log |
| `validated_unit` | command | Unit test that passed |
| `validated_e2e` | command | E2E test that passed |
| `tests_failed` | `"timestamp command"` | Red phase marker |
| `tests_reviewed` | timestamp | Set by /approve-tests |
| `objective_verified` | ISO8601 | Verification timestamp |
| `objective_verified_hash` | plan hash | Hash at verification time |
| `objective_verified_edit_count` | decimal | Edit count at verification time |
| `objective_verified_evidence` | command | Exact verification command |
| `diagnostic_mode` | `"1"` | Investigation mode active |
| `validate_pending` | description | Manual verification pending |
| `validate_pending_hash` | plan hash | Hash when pending set |
| `accept_bypass_pending` | timestamp | /accept blocked, awaiting retry |
| `accept_bypass_pending_hash` | plan hash | Hash when bypass pending |
| `user_bypass` | ISO8601 | User confirmed bypass |
| `user_bypass_hash` | plan hash | Hash when bypass confirmed |

### Invariants

1. **Conversation isolation:** State written by conversation A MUST NOT be visible to conversation B. In production: enforced by `conversation_id` column. In test: enforced by `CLAUDE_TEST_PERSIST_DIR`.
2. **Test override:** `CLAUDE_TEST_PERSIST_DIR` forces flat-file mode — the entire SQLite path is bypassed. All existing tests pass unchanged.
3. **Single source of truth:** All state access MUST go through `state_read()`/`state_write()`. No script may use raw `${PERSIST_DIR}/filename` paths.
4. **Atomic approval:** `write_approval_bundle()` clears `approved` first, writes all metadata, then sets `approved` last — preventing partial state.
5. **Bulk cleanup:** `clear_all_state()` replaces individual `rm -f` lists. In SQLite mode this is a single `DELETE FROM state` — atomic and complete.

### Conversation identity resolution (`init_persist_dir`)

Production mode resolves `CONV_ID` with priority:

1. `SESSION_ID` (from hook JSON) → look up `sessions` table
2. `CONVERSATION_TOKEN` env var → look up `conversations` table
3. MEMORY.md token → look up `conversations` table
4. Most recent active conversation for `project_dir`
5. Create new conversation (random hex token)

After resolution, the session is registered in `sessions` and `last_active` is updated.

### CONVERSATION_TOKEN

- Generated via `openssl rand -hex 8`
- Used as `conversations.id` in SQLite (production mode)
- Stored in MEMORY.md under `## Conversation Token` (survives compaction)
- Read by `read_conversation_token()` in `common.sh`

### Additional state functions (SEP-010)

- `state_append(key, value)` — appends to existing value with newline separator (for `validation_log`)
- `clear_all_state()` — removes all state for the current conversation (replaces bulk `rm -f` lists)
- `counter_increment(key)` — atomic increment in SQLite mode via `ON CONFLICT DO UPDATE`
- `log_event(type, detail)` — records events in the `events` table (production only)

---

## 4. Plan File Contract

### Storage

Plan files live in `~/.claude/plans/{CONVERSATION_TOKEN}/`. Each conversation has its own plan directory. `conversation_plan_dir()` in `common.sh` returns the correct path. `newest_plan_file()` only scans the calling conversation's plan directory.

### Resolution order

1. **Explicit pointer** — `state_read plan_file` (set at approval time, conversation-scoped)
2. **Active plan marker** — `~/.claude/.claude_active_plan` (project-wide, weaker)
3. **Planning window** — `newest_plan_file(planning_started_at)` scoped to conversation's plan directory
4. **Newest on disk** — `newest_plan_file(0)` scoped to conversation's plan directory (last resort)

### Invariants

1. Plan files created by conversation A MUST NOT collide with conversation B.
2. `plan_is_done()` plans (marked `**Status: DONE**`) are excluded from resolution.
3. Plans older than 4 hours are rejected by `validate_plan_quality.sh`.

### Cleanup

Completed plans may be archived or deleted. No plan file persists indefinitely.

---

## 5. Hook Responsibilities Matrix

| Script | Event | Tool matcher | Reads | Writes | Decision |
|---|---|---|---|---|---|
| `check_clear_approval_command.sh` | UserPromptSubmit | (all) | prompt, approved, planning, tests_failed, tests_reviewed, dirty, objective, scope, criteria, edit_count, diagnostic_mode | diagnostic_mode | allow with context |
| `require_plan_approval.sh` | PreToolUse | Edit\|Write\|NotebookEdit | file_path, approved, plan_file, plan_hash, scope, objective_verification_required, objective_verification, tests_failed, tests_reviewed | edit_count (increment) | deny or allow with context |
| `validate_plan_quality.sh` | PreToolUse | ExitPlanMode | plan file content, planning_started_at | approved, plan_file, plan_hash, objective, scope, criteria, objective_verification_required, objective_verification; clears planning, planning_started_at | deny or allow |
| `guard_destructive_bash.sh` | PreToolUse | Bash | command | (none) | deny or exit 0 |
| `sep_commit_check.sh` | PreToolUse | Bash | command (git commit) | (none) | deny or exit 0 |
| `require_investigation_plan.sh` | PreToolUse | Read\|Grep\|Glob\|Bash\|Task\|WebFetch\|WebSearch | diagnostic_mode, planning, approved | (none) | deny or exit 0 |
| `clear_plan_on_new_task.sh` | PostToolUse | EnterPlanMode | (none) | clears ALL state; sets planning, planning_started_at | exit 0 |
| `approve_plan.sh` | PostToolUse | ExitPlanMode | approved, planning | clears planning, planning_started_at | exit 0 |
| `track_dirty.sh` | PostToolUse | Edit\|Write\|NotebookEdit | file_path | dirty | exit 0 |
| `track_validation.sh` | PostToolUse | Bash | command | validated_unit, validated_e2e, validated, validation_log; conditionally clears dirty, validated_unit, validated_e2e, tests_failed | allow with context |
| `track_test_failure.sh` | PostToolUseFailure | Bash | command | tests_failed, validation_log | exit 0 |

### Standalone scripts (not hooks — called explicitly)

| Script | Purpose | Key behavior |
|---|---|---|
| `restore_approval.sh` | `/approve` command | Rebuilds approval bundle from newest plan |
| `accept_outcome.sh` | `/accept` command | Preflight check + finalize: marks plan DONE, updates MEMORY.md, clears state |
| `reject_outcome.sh` | `/reject` command | Clears all state |
| `clear_approval.sh` | Post-implementation | Blocks if dirty or objective unverified; clears all state |
| `record_validation.sh` | Record proof | `--command`: records objective verification; `--manual`: records pending user verification |
| `generate_token.sh` | `/new-token` command | Generates conversation token, writes to MEMORY.md |
| `approve_tests.sh` | `/approve-tests` command | Sets tests_reviewed marker |

---

## 6. Concurrency Contract

### What is shared (read-only)

- CLAUDE.md (global instructions)
- Hook scripts (`~/.claude/scripts/`)
- SEP files (`~/.sep/`)

### What is per-conversation (isolated)

- State rows in `~/.claude/workflow.db` keyed by `conversation_id` (production)
- PERSIST_DIR flat files (test mode only)
- Plan files directory (`~/.claude/plans/{TOKEN}/`)
- All approval state, validation state, edit count, dirty flags

### What is per-conversation (single-slot, last-writer-wins)

- MEMORY.md conversation token — each project directory supports one active conversation token in MEMORY.md at a time. When a new conversation generates a token, the previous token is overwritten. In production mode, the `sessions` table provides authoritative session → conversation mapping, making MEMORY.md a backup for compaction recovery only.

### Token resolution in `init_persist_dir()` (production mode)

Resolution priority: `SESSION_ID` → `sessions` table lookup > `CONVERSATION_TOKEN` env var → `conversations` table > MEMORY.md token → `conversations` table > most recent active conversation for project > create new conversation. Using `sessions` table lookup as the primary source eliminates the MEMORY.md single-slot collision for all hook-based flows.

### Invariants

1. Multiple conversations MAY run concurrently in the same project. Each conversation's planning, approval, editing, and validation state MUST be fully isolated.
2. No hook invocation in conversation A may read or write state belonging to conversation B.
3. `init_persist_dir()` is the ONLY function that computes PERSIST_DIR. All scripts MUST call it.

---

## 7. Self-Modification Protocol

Rules for safely editing the hook system itself (scripts in `~/.claude/scripts/`):

### The bootstrapping problem

When you change how PERSIST_DIR is computed (e.g., adding conversation token to the path), the currently-running approval becomes invisible — the hooks now look for state in a different directory than where it was written.

### Rules

1. **Before changing PERSIST_DIR computation:** Copy all state files from the old path to the new path.
2. **After changing PERSIST_DIR computation:** Run `/approve` to rebuild approval at the new path if the copy didn't work.
3. **Never compute PERSIST_DIR inline.** Always use `init_persist_dir()`. This ensures a single place to update.
4. **Test with `CLAUDE_TEST_PERSIST_DIR`.** The test harness bypasses token scoping, so existing tests continue to work even when the production path changes.
5. **When editing hooks that enforce the workflow:** Be aware that the hooks are live. A syntax error in `require_plan_approval.sh` will block ALL subsequent edits. Keep a terminal open with `~/.claude/scripts/restore_approval.sh` ready.

---

## 8. Compaction Recovery Protocol

### What survives compaction

- CLAUDE.md (re-read from disk)
- First 200 lines of MEMORY.md (including conversation token)
- All state marker files on disk (PERSIST_DIR)
- This architecture document (if referenced from CLAUDE.md)

### What is lost

The model's in-context awareness of: current workflow phase, plan content, edit progress, which files were already changed, what the objective is.

### Recovery mechanism

The `UserPromptSubmit` hook (`check_clear_approval_command.sh`) injects a `── WORKFLOW STATE ──` block on every user message. This block reads persistent markers and reconstructs: current phase (APPROVED/PLANNING/IMPLEMENTING), objective, scope, plan file path, edit count, TDD phase, dirty/validation status.

### Decision tree for the model after compaction

```
Read the injected WORKFLOW STATE block — it tells you exactly where you are.

├─ APPROVED with edits > 0:
│   You are mid-implementation.
│   → Read the plan file (path is in the injection).
│   → Continue editing only files listed in scope.
│
├─ APPROVED with edits = 0:
│   You have a fresh approval.
│   → Read the plan file.
│   → Start Phase A (write tests).
│
├─ PLANNING:
│   You are writing a plan.
│   → Look for the newest plan file in the conversation's plan directory.
│   → Continue writing it.
│
├─ No workflow state:
│   You are idle.
│   → Wait for user instruction.
│
└─ IN ALL CASES:
    → You MUST NOT guess what you were doing.
    → You MUST read the injected state and the plan file.
    → Trust the injection over your memory.
```

---

## 9. Concurrent Session Protocol

### Correct behavior

- **State isolation:** Each conversation has its own PERSIST_DIR (`{PROJECT_HASH}/{TOKEN}/`). Approval, validation, edit count, dirty flags — all isolated. No conversation can read or write another conversation's state.
- **Plan file isolation:** Each conversation writes plans to `~/.claude/plans/{TOKEN}/`. Plan resolution functions (`newest_plan_file()`, `resolve_plan_file()`) only scan the conversation's own subdirectory.
- **Token storage:** Each conversation's token is stored in its own PERSIST_DIR. MEMORY.md holds the most recent token as a convenience for compaction recovery, but is NOT the authoritative token store for concurrent sessions.
- **Invariant:** Two conversations MAY both be in active planning or editing phases simultaneously without interference. Neither conversation's hooks, state, or plan files affect the other.

---

## 10. Failure Loop Prevention

Prescriptive decision trees. The model MUST follow these exactly — no improvisation.

### When an edit is BLOCKED

```
Read the EXACT error message from the hook.

├─ "No approved plan"
│   ├─ Plan file exists? → Call ExitPlanMode (NOT EnterPlanMode)
│   └─ No plan file? → Call EnterPlanMode, write plan, call ExitPlanMode
│
├─ "File not in approved scope"
│   → Edit your plan file: add the path to ## Scope.
│   → Call ExitPlanMode.
│   → Retry edit.
│
├─ "Plan quality checks failed"
│   → Read the listed errors.
│   → Fix each one in the plan file.
│   → Call ExitPlanMode.
│
├─ "Approval metadata is stale or incomplete"
│   → Tell user to type /approve.
│   → Do NOT call ExitPlanMode or EnterPlanMode.
│
├─ "TDD ENFORCEMENT: Tests must fail first"
│   → Write test files.
│   → Run them with a test runner.
│   → They must exit non-zero.
│
├─ "TEST REVIEW GATE"
│   → Show test files to user.
│   → Wait for /approve-tests or /skip-tests.
│
└─ Any other message
    → Read it literally.
    → Do what it says.
    → Do NOT retry the same action.
```

### When a Bash command fails

```
├─ Exit code non-zero from test runner?
│   → This is expected (TDD red phase). Proceed.
│
├─ Same command failed twice?
│   → STOP. Do not retry.
│   → List 3 possible causes with evidence.
│   → Form a theory. Ask user.
│
├─ Permission denied / command not found?
│   → Do NOT retry with sudo or workarounds.
│   → Report the error to the user.
│
└─ Hook script error (e.g., record_validation.sh)?
    → Read the EXACT error output.
    → It tells you what's wrong and what to do.
```

### When the workflow is stuck

```
├─ "dirty" flag won't clear?
│   → Need BOTH unit AND E2E tests to pass.
│   → Check which tier is missing.
│
├─ "objective not verified"?
│   → Run the EXACT command from ## Objective Verification.
│   → Then: record_validation.sh --command "exact command"
│
├─ Can't find plan file?
│   → Check the conversation's plan directory for recent .md files.
│   → Or tell user to type /approve.
│
├─ State seems wrong after compaction?
│   → Read the WORKFLOW STATE injection. Trust it over your memory.
│   → Read the plan file path from the injection. Read that file.
│
└─ Editing the hook system itself broke approval?
    → Copy state files from old PERSIST_DIR to new PERSIST_DIR.
    → Or tell user to type /approve.
```

### Universal rule

If you attempt the same action 3 times and it fails, STOP. Report what you tried, what failed, and ask the user for guidance. Never brute-force.

---

## 11. Implementation Status

Items where the code does not yet match this contract:

| Contract requirement | Current state | Tracking |
|---|---|---|
| Plan files in `~/.claude/plans/{TOKEN}/` | Implemented via `conversation_plan_dir()` | SEP-004 ✅ |
| `newest_plan_file()` scoped to conversation | Scans only `conversation_plan_dir()` | SEP-004 ✅ |
| `SESSION_ID` as primary token source | `init_persist_dir()` prefers SESSION_ID from hook JSON | SEP-004 ✅ |
| Dead `approval_token` writes removed | Cleaned from `approve_plan.sh`, `validate_plan_quality.sh`, `clear_plan_on_new_task.sh` | SEP-004 ✅ |
| SQLite state backend | Dual-mode: SQLite in production, flat files in test | SEP-010 ✅ |
| `state_append` / `clear_all_state` | Implemented in `common.sh` | SEP-010 ✅ |
| Conversation identity via `sessions` table | SESSION_ID → conversation lookup in SQLite | SEP-010 ✅ |
| Stale conversation cleanup | `cleanup_stale_sessions.sh` deletes conversations inactive 7+ days | SEP-010 ✅ |
| Orphaned plan file cleanup | 119+ orphaned plans, no cleanup mechanism | Needs design |
| `PreCompact` hook for state snapshot | Not used | Optional enhancement |
