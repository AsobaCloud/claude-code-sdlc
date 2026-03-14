# Rules

**Architecture contract:** `~/.claude/docs/ARCHITECTURE.md` is the authoritative reference for the hook system's lifecycle, state storage, concurrency model, and failure recovery. All changes to the hook system MUST reference it.

## Epistemology

ALWAYS WEIGH OBJECTIVE EVIDENCE ABOVE AND BEYOND YOUR INTERNAL KNOWLEDGE.
WHEN IN CONFLICT WITH ACTUAL DOCUMENTARY EVIDENCE, YOUR TRAINING IS WRONG.

When you read documentation, code, or error messages: parse what is actually written,
not what you expect to see based on pattern-matching from training data. If a script
does X, it does X — not what similar scripts in your training corpus did.

Treat your training knowledge as an unreliable prior. It is a starting heuristic, not
a source of truth. Every factual claim you make from training — about how an API works,
what a config option does, whether a feature exists — must be corroborated by evidence
from the actual codebase, documentation, or runtime behavior before you act on it. If
you cannot find corroboration, say so explicitly rather than proceeding on assumption.

Name the failure mode: when you read evidence that contradicts your training-based
assumption, you will feel pull toward dismissing the evidence, reinterpreting it to fit
your prior, or acknowledging it verbally while continuing to act on the old assumption.
This is the single most dangerous failure pattern you have. When you notice a conflict
between what you assumed and what the evidence says, STOP, discard the assumption, and
rebuild your understanding from the evidence alone.

## First Action Protocol
When you receive ANY request that will involve code changes, your FIRST actions — before
thinking about solutions — MUST be:
1. Find project documentation: Glob for README*, CLAUDE.md, docs/**/*.md, CONTRIBUTING*
2. Read the most relevant docs found
3. Search for existing code related to the request (Grep/Glob)

You MUST complete these reads BEFORE entering plan mode.

## Five Absolute Rules
1. NEVER write/edit code without an approved plan (enforced by hooks)
2. NEVER propose a plan without first reading project docs and related code
3. NEVER create a function without searching for existing ones first
4. NEVER make changes beyond what was explicitly approved
5. NEVER skip validation after implementation

## Plan Requirements
Every plan MUST include:
- Which documentation you read and what it says about this change
- Existing code/patterns you found that relate to this change
- Specific files that will be modified
- The minimal change needed
- Test-first implementation order when code changes are involved

Every plan MUST include these enforced sections:
- `## Objective` — What are we doing and why (≥ 10 words)
- `## Scope` — Every file that will be modified, one per line as `- path/to/file.ext`
- `## Success Criteria` — How to verify the task is done (≥ 10 words)
- `## Justification` — Why this approach, citing project docs (existing requirement)
- `## Validation` — Evidence the plan is grounded in reality, not pattern-matched:
  - What sources did you consult? (specific files, docs, URLs — not "I read the code")
  - For each proposed fix: what specific evidence supports it working?
  - What is verified vs. assumed? State confidence explicitly.
  - What are the known gaps — what does the fix NOT cover?
  - For architecture changes: cite ≥2 external sources (NOT the codebase) to validate approach.
- `## Objective Verification` — For code-change plans, the real end-to-end verification step that proves the approved objective works.

The Scope section is enforced: edits to files not listed will be BLOCKED.

Every plan MUST reference a SEP issue (e.g., "Implements SEP-003") unless the project
has a `.sep-exempt` marker. If no SEP exists, create one during planning via Bash:
`~/.claude/scripts/sep_create.sh "title" "summary" "motivation" "change" "criteria"`

## Test-Driven Implementation Order (Mechanically Enforced)

When a plan involves code changes, implementation MUST follow this order:

- **Phase A — Write failing tests first.** Write tests that cover the planned behavior,
  then run them to confirm they fail. This validates that the tests actually detect the
  absence of the new code. The hook system enforces this: production code edits are
  **blocked** until a `tests_failed` marker exists (set automatically when a test runner
  command exits non-zero via `PostToolUseFailure` hook).
- **Phase B — Implement until all tests pass.** Write the minimal production code needed
  to make the failing tests pass. Do not move beyond Phase B until all tests are green.
- **Exception:** Documentation-only changes (`.md`, `.mdx`, `.txt`, `.rst`, plans, SEPs)
  do not require Phase A/B ordering.

**How it works:**
- Test files are always editable (recognized patterns: `test_*.py`, `*_test.py`,
  `*_test.go`, `*.test.ts`, `*.spec.ts`, files under `tests/`, `test/`, `__tests__/`, `spec/`).
- Production file edits require the `tests_failed` marker (proves tests were written and failed).
- The marker is set by `PostToolUseFailure` on Bash when a test runner command fails.
- Tests that pass immediately (fake tests) do NOT unlock production code editing.
- The marker is cleared when two-tier validation completes or a new plan cycle starts.

### Test Review Gate (human checkpoint)

After tests are written and fail, production code edits remain BLOCKED until the
user reviews the tests. The model MUST present test files to the user and wait for:
- `/approve-tests` — user confirms tests are meaningful
- `/skip-tests` — user bypasses testing entirely (e.g., config changes, CSS tweaks)

## UI Changes Require ASCII Mockups
When a plan involves ANY visual/UI change, the plan MUST include an ASCII mockup
showing the proposed layout BEFORE and AFTER. No UI code without a visual preview.

## Git Commits
Never add "Co-Authored-By: Claude" or any self-attribution to commit messages.

## Debugging Workflow
When something doesn't work, DO NOT immediately jump to code changes:
1. List at least 3 possible causes with evidence for/against each
2. Form a theory based on evidence
3. Write an implementation plan for the fix
4. Get approval before writing code

---

## Investigation Protocol - ENFORCED FOR DIAGNOSTIC QUESTIONS

When a user asks a diagnostic question (errors, failures, "what happened", "why is X broken",
etc.), investigation mode activates automatically:

1. First submission is **blocked** as a speed bump — re-submit to enter investigation mode
2. All tools (Read, Grep, Glob, Bash, Task, WebFetch, WebSearch) are **blocked** until
   you enter plan mode and get an investigation plan approved
3. Only `EnterPlanMode` is available during the lockout

### Investigation Plan Requirements

Investigation plans use `## Hypothesis` instead of standard code-change sections:

- `## Objective` — What you are investigating and why (≥10 words)
- `## Hypothesis` — What might be wrong, with stated confidence levels (≥15 words)
- `## Investigation Steps` — Specific checks to run: commands, files, logs (≥20 words)
- `## Scope` — Systems, files, or logs to examine (no local file path requirement)
- `## Success Criteria` — How to know the investigation is complete (≥10 words)
- `## Validation` — What is known vs. assumed before investigating (≥20 words)

**Not required** for investigation plans: ## Justification, SEP reference

### Critical Rules

- Do NOT make diagnostic claims before investigating
- Do NOT offer "preliminary assessments" or reassurances
- Every finding must cite specific evidence (file, log line, command output)
- State confidence explicitly: "confirmed by X" vs "suspected based on Y"

### Escape Hatch

User types `/skip-investigation` to bypass investigation mode for any question.

---

## Hook System - ENFORCED WORKFLOW

Hooks **BLOCK Edit/Write/NotebookEdit** until plan approval.
Hooks **BLOCK ExitPlanMode** if plan quality is insufficient.
Approval is stored **per conversation** (project hash + conversation token). Each
conversation has isolated state — approval in one conversation is not visible to another.

### The Workflow

1. `EnterPlanMode` → clears previous approval, enters planning
2. Explore codebase: Read docs, Grep/Glob for related code
3. Write substantive plan to plan file (50+ words, all required sections)
4. `ExitPlanMode` → validates plan quality → approved → editing unlocked
5. Implement ONLY the changes described in the plan
6. **Validate** — run tests or verification commands. Edits set a `dirty` flag. For code-change plans, the approved `## Objective Verification` step must be recorded before the task can complete.
7. Run `~/.claude/scripts/clear_approval.sh` → blocked if `dirty` exists or the current plan objective is unverified.
8. Only after objective verification exists may you tell the user to `/accept` or `/reject`.

### Validation State Markers

- `dirty` — set automatically when a non-exempt file is edited; cleared when two-tier validation completes or approved objective proof is recorded
- `validated_unit` — set when a unit test command passes (cleared after both tiers complete)
- `validated_e2e` — set when an E2E/integration test command passes (cleared after both tiers complete)
- `validated` — records the last validation command that was run
- `validation_log` — append-only log of all validation commands with timestamps
- `objective_verification_required` — `1` when the current approved plan requires real end-to-end objective proof
- `objective_verified` — timestamp showing the current plan objective was verified
- `objective_verified_hash` — the `plan_hash` that the objective proof applies to
- `objective_verified_evidence` — the exact approved verification command that proved the objective

**Two-tier requirement:** Both a unit test AND an E2E/integration test must pass before the dirty flag clears. Running only one tier records progress but does NOT unlock completion.

Recognized **unit test** commands (detected automatically via PostToolUse on Bash):
`npm test`, `pytest`, `go test`, `cargo test`, `make test`, `bun test`, and other standard test runners.

Recognized **E2E/integration test** patterns (commands containing these keywords):
`e2e`, `end-to-end`, `integration`, `functional`, `cypress`, `playwright`, `selenium`, `puppeteer`, `--e2e`, `--integration`

Examples: `npm run test:e2e`, `npx cypress run`, `npx playwright test`, `pytest --e2e`, `make test-integration`

To record approved objective proof:
`~/.claude/scripts/record_validation.sh --command "exact approved verification command"`

To record that manual user verification is pending:
`~/.claude/scripts/record_validation.sh --manual "what the user must verify"`

The agent may not bypass missing proof. Only the user may manually bypass by invoking `/accept`.

### Writes Allowed During Planning (no approval needed)

- Plan files: `*/.claude/plans/*`
- SEP files: `*/.sep/*`
- Memory files: `*/.claude/projects/*/memory/*`

Everything else requires approval.

### When Blocked

**"No approved plan"** → Call `EnterPlanMode` to start planning.
**"File not in scope"** → Update plan's `## Scope`, call `ExitPlanMode` for re-approval.
**"Plan quality checks failed"** → Fix the listed issues in plan file, call `ExitPlanMode` again.
**"git commit must reference SEP"** → Run `~/.claude/scripts/sep_create.sh "title"` via Bash.

### Emergency escape hatch

If approval is lost: user types `/approve` or runs `~/.claude/scripts/restore_approval.sh`

### What NOT To Do

- DO NOT use Bash (tee, echo >) to bypass Write blocks on project files
- DO NOT create state marker files directly
- DO NOT make edits after running clear_approval.sh — you are locked out
- DO NOT make edits beyond what the approved plan describes
- DO NOT call clear_approval.sh without running validation first — it will be blocked
- DO NOT tell the user to `/accept` unless the current plan objective has been verified
