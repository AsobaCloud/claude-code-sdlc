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
  │ Both must pass → dirty clears, validation_complete set
  ▼
VERIFYING
  │ Invoke /verify → launches qa-verifier agent
  │ Agent receives only objective + success criteria (epistemic isolation)
  │ Agent generates ≥1 verification step per criterion, runs them
  │ All pass → agent calls record_validation.sh + clear_approval.sh
  ▼
VERIFIED
  │ objective_verified marker set by record_validation.sh --command
  ▼
COMPLETED
  │ clear_approval.sh → user /accept or /reject
  ▼
IDLE
```

### Investigation plans (voluntary)

The model may voluntarily write an investigation plan using `## Hypothesis` instead of `## Justification`. The plan validation system (`validate_plan_quality.sh`) recognizes this format and relaxes the SEP reference requirement. This is not mechanically enforced — no automatic detection or tool blocking occurs.

### Recovery paths

| Command | From state | Effect |
|---|---|---|
| `/approve` | Any | Rebuilds approval bundle from newest plan |
| `/reject` | IMPLEMENTING+ | Clears all state, forces re-planning |
| `/skip-tests` | TESTS_WRITTEN | Bypasses TDD gate entirely |
| `/accept` (twice) | VERIFIED (no proof) | User bypass of objective verification |

---

## 3. State Storage Contract

### SQLite backend (SEP-010, SEP-006)

All state is stored in a SQLite database at `~/.claude/workflow.db`. Tests override `HOME` to use a temporary database — no dual-mode or flat-file fallback exists.

The `state_read()`/`state_write()`/`state_exists()`/`state_remove()` API provides conversation-scoped key-value storage. Scripts use these functions exclusively.

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
    key             TEXT NOT NULL,
    value           TEXT,
    updated_at      TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (conversation_id, key)
);

CREATE TABLE plans (
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

CREATE TABLE events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id TEXT NOT NULL,
    session_id      TEXT,
    timestamp       TEXT NOT NULL DEFAULT (datetime('now')),
    event_type      TEXT NOT NULL,
    detail          TEXT
);
```

### State keys

| Key | Value | Description |
|---|---|---|
| `approved` | `"1"` | Plan is approved |
| `plan_file` | absolute path | Approved plan file |
| `plan_hash` | SHA256 hex | Plan hash at approval time |
| `objective` | text | Extracted from ## Objective |
| `previous_objective` | text | Objective from prior plan cycle (compaction recovery) |
| `previous_plan_file` | path | Plan file from prior plan cycle (compaction recovery) |
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
| `validation_complete` | ISO8601 | Set when both unit and E2E tiers pass; triggers VERIFYING phase |
| `tests_failed` | `"timestamp command"` | Red phase marker |
| `tests_reviewed` | timestamp | Set by /approve-tests |
| `objective_verified` | ISO8601 | Verification timestamp |
| `objective_verified_hash` | plan hash | Hash at verification time |
| `objective_verified_edit_count` | decimal | Edit count at verification time |
| `objective_verified_evidence` | command | Exact verification command |
| `validate_pending` | description | Manual verification pending |
| `validate_pending_hash` | plan hash | Hash when pending set |
| `accept_bypass_pending` | timestamp | /accept blocked, awaiting retry |
| `accept_bypass_pending_hash` | plan hash | Hash when bypass pending |
| `user_bypass` | ISO8601 | User confirmed bypass |
| `user_bypass_hash` | plan hash | Hash when bypass confirmed |

### Selective clear functions

No function may blanket-delete all state. Two selective clear functions replace the old `clear_all_state()`:

- **`clear_workflow_keys()`** — removes workflow-lifecycle keys: `approved`, `plan_file`, `plan_hash`, `scope`, `criteria`, `objective_verification`, `objective_verification_required`, `planning`, `planning_started_at`, `dirty`, `validated`, `validation_log`, `validated_unit`, `validated_e2e`, `tests_failed`, `tests_reviewed`, `objective_verified`, `objective_verified_hash`, `objective_verified_edit_count`, `objective_verified_evidence`, `validate_pending`, `validate_pending_hash`, `accept_bypass_pending`, `accept_bypass_pending_hash`, `user_bypass`, `user_bypass_hash`, `edit_count`. Does NOT remove plan context keys or `last_sep_ref`.
- **`clear_plan_context_keys()`** — removes `objective`, `previous_objective`, `previous_plan_file`. Used alongside `clear_workflow_keys` when fully resetting for a new task.

### Plan query helpers

- `save_plan(file_path, content, status)` — INSERT into plans table with computed hash
- `get_current_plan()` — SELECT most recent approved/draft plan for CONV_ID
- `get_previous_plan()` — SELECT most recent approved/done plan for CONV_ID
- `update_plan_status(plan_id, status)` — UPDATE status, set completed_at if 'done' or 'rejected'

### Invariants

1. **Conversation isolation:** State written by conversation A MUST NOT be visible to conversation B. Enforced by `conversation_id` column in all tables.
2. **Single source of truth:** All state access MUST go through `state_read()`/`state_write()`. No script may use raw `${PERSIST_DIR}/filename` paths.
3. **Atomic approval:** `write_approval_bundle()` clears `approved` first, writes all metadata, then sets `approved` last — preventing partial state.
4. **No blanket deletes:** No function may execute an unscoped `DELETE FROM state`. All deletions use explicit key lists via `clear_workflow_keys()` and `clear_plan_context_keys()`.
5. **Plan content in SQLite:** After approval, plan content is stored in the `plans` table. The disk file remains as the input source; SQLite is authoritative after approval.

### Conversation identity resolution (`init_persist_dir`)

Resolves `CONV_ID` with priority:

1. `SESSION_ID` (from hook JSON) → look up `sessions` table → if found, use mapped `CONV_ID`
2. `SESSION_ID` not found → check MEMORY.md token (via `CONVERSATION_TOKEN` env or `read_conversation_token()`) → if found, map session to that conversation
3. `SESSION_ID` not found, no MEMORY.md token → use `SESSION_ID` as `CONV_ID` (new conversation)
4. No `SESSION_ID` → `CONVERSATION_TOKEN` env var or MEMORY.md token → use as conversation ID
5. No token available → fall back to `"no-token"`

Step 2 is the compaction recovery path: when Claude Code assigns a new `session_id` after compaction, the old conversation's token in MEMORY.md allows the new session to map to the existing conversation, preserving all state.

After resolution, the session is registered in `sessions` and `last_active` is updated.

### CONVERSATION_TOKEN

- Generated via `openssl rand -hex 8`
- Used as `conversations.id` in SQLite
- Stored in MEMORY.md under `## Conversation Token` (survives compaction)
- Read by `read_conversation_token()` in `common.sh`

### Additional state functions

- `state_append(key, value)` — appends to existing value with newline separator (for `validation_log`)
- `counter_increment(key)` — atomic increment via `ON CONFLICT DO UPDATE`
- `log_event(type, detail)` — records events in the `events` table

---

## 4. Plan File Contract

### Storage

Plan files are written to disk by the model at `~/.claude/plans/{CONVERSATION_TOKEN}/`. Each conversation has its own plan directory. `conversation_plan_dir()` in `common.sh` returns the correct path.

After approval, plan content is stored in the SQLite `plans` table via `save_plan()`. The disk file remains as the input source (the model writes drafts to disk via the Write tool); SQLite becomes authoritative after approval.

### Resolution order (`resolve_plan_file`)

1. **Explicit pointer** — `state_read plan_file` (set at approval time, conversation-scoped)
2. **Plans table** — query `plans` table for most recent approved plan for this conversation
3. **Planning window** — `newest_plan_file(planning_started_at)` scoped to conversation's plan directory
4. **Newest on disk** — `newest_plan_file(0)` scoped to conversation's plan directory (last resort)

### Invariants

1. Plan files created by conversation A MUST NOT collide with conversation B.
2. `plan_is_done()` plans (marked `**Status: DONE**`) are excluded from resolution.
3. Plans older than 4 hours are rejected by `validate_plan_quality.sh`.
4. After approval, plan content exists in both the disk file and the `plans` table.

### Cleanup

Completed plans may be archived or deleted. No plan file persists indefinitely.

---

## 5. Hook Responsibilities Matrix

| Script | Event | Tool matcher | Reads | Writes | Decision |
|---|---|---|---|---|---|
| `check_clear_approval_command.sh` | UserPromptSubmit | (all) | approved, planning, tests_failed, tests_reviewed, dirty, objective, scope, criteria, edit_count | (none) | allow with context |
| `require_plan_approval.sh` | PreToolUse | Edit\|Write\|NotebookEdit | file_path, approved, plan_file, plan_hash, scope, objective_verification_required, objective_verification, tests_failed, tests_reviewed | edit_count (increment) | deny or allow with context |
| `validate_plan_quality.sh` | PreToolUse | ExitPlanMode | plan file content, planning_started_at | approved, plan_file, plan_hash, objective, scope, criteria, objective_verification_required, objective_verification; clears planning, planning_started_at | deny or allow |
| `guard_destructive_bash.sh` | PreToolUse | Bash | command | (none) | deny or exit 0 |
| `sep_commit_check.sh` | PreToolUse | Bash | command (git commit) | (none) | deny or exit 0 |
| `clear_plan_on_new_task.sh` | PostToolUse | EnterPlanMode | objective, plan_file | clears workflow keys + plan context keys; preserves previous_objective, previous_plan_file; sets planning, planning_started_at | exit 0 |
| `approve_plan.sh` | PostToolUse | ExitPlanMode | approved, planning | clears planning, planning_started_at | exit 0 |
| `track_dirty.sh` | PostToolUse | Edit\|Write\|NotebookEdit | file_path | dirty | exit 0 |
| `track_validation.sh` | PostToolUse | Bash | command | validated_unit, validated_e2e, validated, validation_log; conditionally clears dirty, validated_unit, validated_e2e, tests_failed | allow with context |
| `track_test_failure.sh` | PostToolUseFailure | Bash | command | tests_failed, validation_log | exit 0 |

### Standalone scripts (not hooks — called explicitly)

| Script | Purpose | Key behavior |
|---|---|---|
| `restore_approval.sh` | `/approve` command | Rebuilds approval bundle from newest plan |
| `accept_outcome.sh` | `/accept` command | Preflight check + finalize: marks plan DONE in plans table, updates MEMORY.md, selective clear (workflow + context keys) |
| `reject_outcome.sh` | `/reject` command | Marks plan 'rejected' in plans table, selective clear (workflow + context keys) |
| `clear_approval.sh` | Post-implementation | Blocks if dirty or objective unverified; selective clear (workflow + context keys) |
| `record_validation.sh` | Record proof | `--command`: records objective verification; `--manual`: records pending user verification |
| `generate_token.sh` | `/new-token` command | Generates conversation token, writes to MEMORY.md |
| `approve_tests.sh` | `/approve-tests` command | Sets tests_reviewed marker |

### Agents

| Agent | Purpose | Key behavior |
|---|---|---|
| `tdd-test-writer` | Phase A — write failing tests | Receives objective + criteria + scope only; writes test files; MUST NOT read plan details |
| `tdd-implementer` | Phase B — make tests pass | Receives test file paths + scope only; writes production code; MUST NOT read plan or test rationale |
| `qa-verifier` | VERIFYING phase — acceptance checks | Receives objective + criteria only (epistemic isolation); generates ≥1 verification step per criterion; reports structured pass/fail; calls `record_validation.sh` and `clear_approval.sh` only on all-pass |

### Skills and commands

| Skill/Command | Purpose |
|---|---|
| `/tdd` | Orchestrates the red-green-refactor cycle using isolated subagents; hands off to `/verify` after Phase B/C |
| `/verify` | Runs the VERIFYING phase: extracts objective + criteria from plan, launches `qa-verifier` agent with epistemic isolation |

---

## 6. Concurrency Contract

### What is shared (read-only)

- CLAUDE.md (global instructions)
- Hook scripts (`~/.claude/scripts/`)
- SEP files (`~/.sep/`)

### What is per-conversation (isolated)

- State rows in `~/.claude/workflow.db` keyed by `conversation_id`
- Plan rows in `plans` table keyed by `conversation_id`
- Plan files directory (`~/.claude/plans/{TOKEN}/`)
- All approval state, validation state, edit count, dirty flags

### What is per-conversation (single-slot, last-writer-wins)

- MEMORY.md conversation token — each project directory supports one active conversation token in MEMORY.md at a time. When a new conversation generates a token, the previous token is overwritten. In production mode, the `sessions` table provides authoritative session → conversation mapping, making MEMORY.md a backup for compaction recovery only.

### Token resolution in `init_persist_dir()` (production mode)

Resolution priority: (1) `SESSION_ID` → `sessions` table lookup; (2) `SESSION_ID` not found → check MEMORY.md token → map session to that conversation (compaction recovery); (3) `SESSION_ID` not found, no MEMORY.md token → use `SESSION_ID` as `CONV_ID`; (4) no `SESSION_ID` → `CONVERSATION_TOKEN` env var or MEMORY.md token; (5) fall back to `"no-token"`. Step 2 ensures that after compaction (new `session_id`), the MEMORY.md token maps the new session to the existing conversation, preserving all state.

### Invariants

1. Multiple conversations MAY run concurrently in the same project. Each conversation's planning, approval, editing, and validation state MUST be fully isolated.
2. No hook invocation in conversation A may read or write state belonging to conversation B.
3. `init_persist_dir()` is the ONLY function that computes PERSIST_DIR. All scripts MUST call it.

---

## 7. Self-Modification Protocol

Rules for safely editing the hook system itself (scripts in `~/.claude/scripts/`):

### The bootstrapping problem

When you change state storage logic (e.g., modifying `init_persist_dir` or `state_read`/`state_write`), the currently-running approval may become invisible if the hooks can no longer locate state. In production mode, state lives in `~/.claude/workflow.db` keyed by `conversation_id` — it survives path changes automatically. The risk is breaking the lookup logic itself.

### Rules

1. **State survives path changes.** State is in SQLite keyed by `conversation_id`, not file paths. Changing `PERSIST_DIR` computation does not lose state. If approval becomes invisible after a change, run `/approve` to rebuild it.
2. **Never compute PERSIST_DIR inline.** Always use `init_persist_dir()`. This ensures a single place to update.
3. **Test with HOME override.** The test harness overrides `HOME` to use a temporary SQLite database. All tests exercise the real SQLite code path.
4. **When editing hooks that enforce the workflow:** Be aware that the hooks are live. A syntax error in `require_plan_approval.sh` will block ALL subsequent edits. Keep a terminal open with `~/.claude/scripts/restore_approval.sh` ready.

---

## 8. Compaction Recovery Protocol

### What survives compaction

- CLAUDE.md (re-read from disk)
- First 200 lines of MEMORY.md (including conversation token)
- All state in `~/.claude/workflow.db` (keyed by `conversation_id`)
- This architecture document (if referenced from CLAUDE.md)

### What is lost

The model's in-context awareness of: current workflow phase, plan content, edit progress, which files were already changed, what the objective is.

### Recovery mechanism

The `UserPromptSubmit` hook (`check_clear_approval_command.sh`) injects a `── WORKFLOW STATE ──` block on every user message. This block reads persistent markers and reconstructs: current phase (APPROVED/PLANNING/IMPLEMENTING), objective, scope, plan file path, edit count, TDD phase, dirty/validation status.

For the PLANNING phase, the injection is enriched with compaction recovery context:
- **Previously working on:** the objective from the prior plan cycle (from `previous_objective` state key)
- **Previous plan:** the plan file from the prior plan cycle (from `previous_plan_file` state key)
- **Current draft:** path to any in-progress draft plan file (from disk scan)

If the breadcrumb state keys are empty (e.g., after compaction erased them before they were written), the hook queries the `plans` table via `get_previous_plan()` for richer context.

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
│   → Check "Previously working on" for context on what you were doing.
│   → Check "Current draft" for any in-progress plan file.
│   → Continue writing the plan.
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

- **State isolation:** Each conversation's state is isolated by the `conversation_id` column in `~/.claude/workflow.db`. Approval, validation, edit count, dirty flags, and plans — all scoped to the conversation. No conversation can read or write another conversation's state.
- **Plan file isolation:** Each conversation writes plans to `~/.claude/plans/{TOKEN}/`. Plan resolution functions (`newest_plan_file()`, `resolve_plan_file()`) only scan the conversation's own subdirectory.
- **Token storage:** MEMORY.md holds the most recent token as a convenience for compaction recovery. In production mode, the `sessions` table provides authoritative session → conversation mapping, making MEMORY.md a backup only.
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
    → Run `/approve` to rebuild approval from plan file.
    → State in SQLite survives path changes; only lookup logic breakage causes this.
```

### Universal rule

If you attempt the same action 3 times and it fails, STOP. Report what you tried, what failed, and ask the user for guidance. Never brute-force.

---

## 11. TDD Subagent System (SEP-013)

### Purpose

The hook-based TDD gates (section 2) enforce **process**: tests must be written, must fail, must be reviewed before production code is editable. But they cannot enforce **epistemic isolation** — when test-writing and implementation happen in the same context window, the model designs tests around the implementation it's already planning.

TDD subagents solve this by running each phase in an isolated context with restricted tool access:

| Agent | Phase | Tools | Isolation |
|---|---|---|---|
| `tdd-test-writer` | A (Red) | Read, Write, Bash, Grep, Glob | No Edit — creates test files only, cannot see implementation plans |
| `tdd-implementer` | B (Green) | Read, Edit, Write, Bash, Grep, Glob | Cannot modify test files, cannot see plans |
| `tdd-refactorer` | C (Refactor) | Read, Edit, Bash, Grep, Glob | No Write — refactors existing files only |

### Relationship to gate system

The subagents work WITH the existing hooks, not around them:

1. **Plan approval** — still required before any editing. The orchestrating context (main conversation) handles planning.
2. **Test-writer writes tests** — test files are always allowed by `require_plan_approval.sh` (lines 119-125).
3. **Test runner fails** — `track_test_failure.sh` sets `tests_failed` marker.
4. **User reviews tests** — `/approve-tests` sets `tests_reviewed` marker.
5. **Implementer edits production code** — gates are satisfied (`tests_failed` + `tests_reviewed` exist).
6. **Validation** — `track_validation.sh` tracks unit and E2E test passing as normal.

### When to use subagents vs. single-context TDD

- **Use subagents** when epistemic isolation matters: new features, complex logic, cases where test design shouldn't be influenced by implementation knowledge.
- **Use single-context** for bug fixes, small changes, or when the implementation is obvious from the test requirements.

The subagents are optional — the standard single-context TDD workflow continues to work unchanged.

### Invocation

The `/tdd` skill (`~/.claude/skills/tdd/SKILL.md`) orchestrates the three-phase workflow. After plan approval, `approve_plan.sh` and `check_clear_approval_command.sh` direct the model to invoke `/tdd`. The skill:

1. Extracts requirements from the approved plan (objective + success criteria only — no implementation details)
2. Launches `tdd-test-writer` via the Agent tool with requirements only (epistemic isolation)
3. Presents test results to user, waits for `/approve-tests`
4. Launches `tdd-implementer` with test file paths and scope (no plan, no test-writing rationale)
5. Optionally launches `tdd-refactorer`

Each agent runs in its own context window with only the tools listed in its frontmatter.

### Test file scope exemption

Test files bypass scope enforcement in `require_plan_approval.sh`. This is necessary because test file names are not known at plan time — the test-writer agent creates them during the red phase. The same file patterns used by the TDD gate (lines 120-125) are checked before the scope denial, and matching files are allowed regardless of scope.

### Agent definitions

Stored at `~/.claude/agents/tdd-{test-writer,implementer,refactorer}.md`. Each is a markdown file with YAML frontmatter specifying `name`, `description`, `tools`, and `model`.

---

## 12. Memory Subsystem (SEPs 016–019)

### Purpose

The memory subsystem provides cross-project learning. Without it, every session starts from zero — the same corrections must be given repeatedly across sessions and projects. The design is inspired by the Sift architecture (Edmonds, 2026): typed memories, FTS5 full-text search, semantic enrichment, and attention scoring — all in SQLite with no external dependencies.

### Schema (`~/.claude/workflow.db`)

```sql
CREATE TABLE memories (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL,            -- feedback, pattern, gotcha, preference
    title TEXT NOT NULL,
    content TEXT,
    keywords TEXT,                  -- comma-separated semantic terms
    anticipated_queries TEXT,       -- natural-language search predictions
    concept_tags TEXT,              -- pipe-delimited hierarchical: |feedback/workflow|
    project_scope TEXT,             -- NULL = global
    correction_count INTEGER DEFAULT 1,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    last_accessed INTEGER,
    access_count INTEGER DEFAULT 0,
    attention_score REAL DEFAULT 0.5
);

CREATE VIRTUAL TABLE memories_fts USING fts5(
    title, content, keywords, anticipated_queries,
    tokenize='porter unicode61'
);
```

### CRUD Functions (`common.sh`)

| Function | Parameters | Purpose |
|---|---|---|
| `memory_write` | id, type, title, content, keywords, project_scope, correction_count, anticipated_queries, concept_tags | Upsert memory + FTS entry (uses Python for safe parameterized insert) |
| `memory_search` | query, limit | FTS5 search ranked by `(correction_count * 2) + bm25() * -1 + (access_count * 0.5)` |
| `memory_top` | limit | Top memories by `(correction_count * 2) + (attention_score * 3) + (access_count * 0.1)` |
| `memory_access` | id | Increment access_count, boost attention_score by 0.15 (capped at 1.0) |

### Semantic Enrichment

Each memory carries three annotation fields populated at write time by the in-context LLM:

- **keywords**: comma-separated semantic terms and synonyms (e.g., "permission, confirmation, redundant, re-confirm")
- **anticipated_queries**: natural-language queries someone might use to find this memory (e.g., "stop asking permission, unnecessary confirmation")
- **concept_tags**: pipe-delimited hierarchical tags for category filtering (e.g., `|feedback/workflow|feedback/autonomy|`)

Keywords and anticipated_queries are indexed in FTS5. Concept tags use SQL `LIKE` prefix matching for hierarchical navigation.

### Attention Scoring

- **Access boost**: each `UserPromptSubmit` injection increments attention by 0.15, capped at 1.0
- **Session decay** (`SessionEnd` hook in `cleanup_old_transcripts.sh`):
  - Feedback: 0.95 retention per session
  - Pattern/preference: 0.98 retention
  - Task/note: 0.85 retention
  - Gotcha: 0.97 retention
- **Tiered injection** in `check_clear_approval_command.sh`:
  - HOT (≥0.7): full title + content snippet
  - WARM (0.25–0.7): title only
  - COLD (<0.25): omitted

### Injection

The `UserPromptSubmit` hook queries `memory_top(10)` and injects a `── LEARNED PATTERNS ──` block into every prompt. Injected memories get their access_count and attention_score boosted. This creates a reinforcement loop: useful memories strengthen, unused ones fade.

### Migration

- `migrate_memories.sh`: ingests `~/.claude/shared-memory/feedback_*.md` files into the database (parses YAML frontmatter for type and correction_count)
- `enrich_memories.sh`: populates anticipated_queries and concept_tags for existing memories

### Invariants

1. Memories are global by default (`project_scope = NULL`). Project-scoped memories filter on the column.
2. FTS5 index is rebuilt on every `ensure_db()` call (DROP + CREATE + repopulate from memories table).
3. All writes go through `memory_write()` which handles both the memories table and FTS sync atomically.
4. Direct `sqlite3` modification of `workflow.db` is blocked by `guard_destructive_bash.sh`.

---

## 13. Implementation Status

| Contract requirement | Current state | Tracking |
|---|---|---|
| Plan files in `~/.claude/plans/{TOKEN}/` | Implemented via `conversation_plan_dir()` | SEP-004 ✅ |
| `newest_plan_file()` scoped to conversation | Scans only `conversation_plan_dir()` | SEP-004 ✅ |
| `SESSION_ID` as primary token source | `init_persist_dir()` prefers SESSION_ID from hook JSON | SEP-004 ✅ |
| SQLite-only state backend | All state in SQLite; tests override HOME for temp DB | SEP-010 ✅ |
| `state_append` / selective clears | `clear_workflow_keys()` + `clear_plan_context_keys()` | SEP-006 ✅ |
| `plans` table for plan content | Plan content stored in SQLite after approval | SEP-006 ✅ |
| No blanket deletes | `clear_all_state()` removed; selective clears only | SEP-006 ✅ |
| Enriched PLANNING injection | Previous objective + draft path in compaction recovery | SEP-006 ✅ |
| Active plan marker removed | `write_active_plan_marker()` / `.claude_active_plan` eliminated | SEP-006 ✅ |
| Conversation identity via `sessions` table | SESSION_ID → conversation lookup in SQLite | SEP-010 ✅ |
| Stale conversation cleanup | `cleanup_stale_sessions.sh` deletes conversations inactive 7+ days | SEP-010 ✅ |
| Orphaned plan file cleanup | 119+ orphaned plans, no cleanup mechanism | Needs design |
| `PreCompact` hook for state snapshot | `precompact_snapshot.sh` captures phase markers and recent events | SEP-006 ✅ |
| TDD subagents for epistemic isolation | Agent definitions + `/tdd` skill + test file scope exemption + hook directives | SEP-013 ✅ |
| SessionEnd transcript cleanup | `cleanup_old_transcripts.sh` deletes transcripts >5 days old | SEP-015 ✅ |
| Cross-project feedback consolidation | 48 per-project memories → 13 shared-memory files with deduplication | SEP-016 ✅ |
| FTS5 memories table | `memories` + `memories_fts` in workflow.db with correction_count ranking | SEP-017 ✅ |
| Semantic enrichment | anticipated_queries, concept_tags, keywords in FTS5 index | SEP-018 ✅ |
| Attention scoring + decay | attention_score with access boost, session-end type-specific decay, tiered injection | SEP-019 ✅ |
| Direct DB write guard | `guard_destructive_bash.sh` blocks `sqlite3` write commands against workflow.db | SEP-020 ✅ |
