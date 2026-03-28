# The Claude Code SDLC: What It Enforces and Why

This document explains the complete software development lifecycle enforced by this hook system. [README.md](README.md) covers architecture and installation. [USER_GUIDE.md](USER_GUIDE.md) covers usage. This document covers the *why*.

## The Problem

Claude Code is technically brilliant but epistemically ungrounded in your codebase. It can produce textbook-perfect code instantly — but not *your* code. It doesn't know your abstractions, your naming conventions, your state management approach, or that you already have a utility that does exactly what it's about to reinvent.

Left to its defaults, Claude Code will:
- Skip reading your code and plan from training-data assumptions
- Write thin plans that sound good but don't reference your actual codebase
- Produce code that technically works but doesn't fit your patterns
- "Helpfully" refactor things you didn't ask it to touch
- Treat a one-line fix as an invitation to restructure a module

The root cause isn't capability — it's a workflow problem. Claude Code's helpfulness bias makes it race to produce code. Instructions telling it to "explore first" are suggestions it can and does ignore. The solution is mechanical enforcement: hooks that block tool execution when steps are skipped.

## The Eight Phases

Every task flows through eight phases. Each phase has a gate — a hook script that blocks progress until the phase's requirements are met. The model experiences correct behavior as the path of least resistance.

```
 [1. Explore] ──► [2. Plan] ──► [3. Review] ──► [4. TDD Red] ──► [5. Implement] ──► [6. Validate] ──► [7. Verify] ──► [8. Complete]
      │                │              │               │                │                  │                 │               │
  First Action     validate_       /approve        require_plan_    require_plan_     track_dirty.sh    /verify          /accept
  Protocol in      plan_quality.sh  (human)        approval.sh      approval.sh       track_            qa-verifier      /reject
  CLAUDE.md        (quality gate)                  (TDD gate:       (scope gate)      validation.sh     agent
                                                    tests must                        (two-tier gate)
                                                    fail first)
```

All state is stored in `~/.claude/workflow.db` (SQLite with WAL mode), scoped per conversation via conversation tokens.

### Phase 1: Exploration

**What:** Claude must explore the docs and code before it plans, and the plan must show evidence of that exploration.

**How:** `clear_plan_on_new_task.sh` starts a fresh planning cycle by clearing prior task state and writing planning markers. The current runtime no longer counts reads through a dedicated exploration hook; instead, `validate_plan_quality.sh` enforces grounded planning indirectly by requiring concrete file references and exploration-evidence language in the plan.

**Why:** Without this expectation, Claude writes plans based on what it *assumes* your code looks like based on its training data. Requiring the plan to cite real files and describe the current codebase keeps planning grounded in the repository rather than in pattern-matched assumptions.

**Enforcement scripts:** `scripts/clear_plan_on_new_task.sh`, `scripts/validate_plan_quality.sh`

### Phase 2: Planning

**What:** Claude must write a structured plan with required sections before any code changes are allowed.

**How:** `validate_plan_quality.sh` runs as a PreToolUse hook on `ExitPlanMode` and checks:

| Check | Requirement | Purpose |
|-------|-------------|---------|
| Plan file exists | `.md` in `~/.claude/plans/` or `.claude/plans/` | No plan = no approval |
| Plan freshness | < 4 hours old | Prevents stale plans from prior sessions |
| Word count | >= 50 words | Blocks one-liner "plans" |
| Required sections | `## Objective`, `## Scope`, `## Success Criteria`, `## Justification`, `## Validation` | Enforces structured thinking |
| Objective verification | `## Objective Verification` for code-change plans | Ties completion to a real end-to-end proof step |
| Scope format | Scope entries must be full absolute paths | Keeps scope enforcement fail-closed |
| Exploration evidence | Keywords like "existing", "found", "current" | Plan must describe what was discovered |
| File references | At least one file path in plan body | Plan must reference real files |
| SEP reference | `SEP-NNN` unless the project is exempt | Keeps plans and commits traceable |

**Why:** A good plan is the highest-leverage artifact in the entire workflow. It forces Claude to articulate *what it found* during exploration and *how it will change things*. This is where training-data assumptions get caught — if the plan says "I'll create a new caching utility" but exploration showed you already have one, the human catches it at review. Without structured planning, Claude jumps straight to code and the human only discovers misalignment after implementation.

**Enforcement script:** `scripts/validate_plan_quality.sh`

### Phase 3: Human Review

**What:** The human reviews the plan and types `/approve` to unlock implementation.

**How:** `approve_plan.sh` runs as a PostToolUse hook on `ExitPlanMode`. It presents the plan to the human. The `/approve` plugin command sets the approval marker in persistent state. Until approval exists, all `Edit`, `Write`, and `NotebookEdit` calls are blocked by `require_plan_approval.sh`.

**Why:** The human is the domain expert. Claude proposes; the human decides. This is the only gate where a human judgment call is required — every other gate is automated. The plan gives the human a structured artifact to review: what will change, which files will be touched, what success looks like. This is dramatically more efficient than reviewing a completed implementation and saying "no, that's wrong, undo it all."

**Enforcement script:** `scripts/approve_plan.sh`, `plugins/plan-workflow/` (`/approve` command)

### Phase 4: TDD Red Phase

**What:** Before editing production code, Claude must write tests that fail. The tests must be reviewed by the user before implementation proceeds.

**How:** `require_plan_approval.sh` checks for a `tests_failed` marker before allowing edits to non-test files. Test files (matching patterns like `test_*.py`, `*.test.ts`, files under `tests/`) are always editable. When a test runner command exits non-zero, `track_test_failure.sh` sets the `tests_failed` marker. The user then reviews the tests and types `/approve-tests` to set `tests_reviewed`, or `/skip-tests` to bypass TDD entirely (for config changes, CSS, documentation).

**Why:** Without TDD enforcement, Claude writes tests that validate its own implementation — circular tests that prove the code does what the code does. By requiring tests to be written and to fail before production code is editable, the tests are designed from requirements, not from implementation knowledge. The `/tdd` skill further strengthens this by delegating test writing to an epistemically isolated `tdd-test-writer` subagent that cannot see the implementation plan.

**Enforcement scripts:** `scripts/require_plan_approval.sh` (TDD gate), `scripts/track_test_failure.sh`, `scripts/approve_tests.sh`, `scripts/skip_tests.sh`

### Phase 5: Scoped Implementation

**What:** Claude can only edit files listed in the plan's `## Scope` section.

**How:** `require_plan_approval.sh` runs as a PreToolUse hook on `Edit|Write|NotebookEdit`. It checks two things: (1) does an approval marker exist, and (2) is the target file listed in the plan's `## Scope`. If either check fails, the edit is blocked.

**Why:** Scope enforcement prevents the most common failure mode of AI-assisted development: scope creep. Without it, Claude treats every task as an invitation to "improve" surrounding code — adding error handling nobody asked for, refactoring adjacent functions, updating docstrings on untouched files. Scope enforcement means "fix the bug in `auth.py`" results in changes to `auth.py` and nothing else.

**Enforcement script:** `scripts/require_plan_approval.sh`

### Phase 5: Validation

**What:** Code changes must be validated, and the approved plan objective must be proven against the real system before the task can complete.

**How:** Two scripts work together:
- `track_dirty.sh` (PostToolUse on `Edit|Write|NotebookEdit`) — sets a `dirty` flag whenever a non-exempt file is edited
- `track_validation.sh` (PostToolUse on `Bash`) — detects test runner commands and manages two-tier validation

The two-tier system (introduced in SEP-005) records:
1. A **unit test** command must pass (npm test, pytest, go test, cargo test, etc.)
2. An **E2E/integration test** command must pass (commands containing e2e, integration, cypress, playwright, etc.)

For code-change plans, that is not sufficient on its own. The approved `## Objective Verification` step must also be recorded for the current `plan_hash`. Running only the tiered tests records progress but does not unlock completion unless the objective proof exists.

**Why:** Code isn't done until the approved objective is shown to work. The dirty flag prevents Claude from declaring victory after writing code but before verifying it works. Unit and integration tests are useful, but the completion gate must be tied to the actual task objective, not just generic green tests.

**Enforcement scripts:** `scripts/track_dirty.sh`, `scripts/track_validation.sh`

### Phase 7: Verification (VERIFYING)

**What:** After two-tier validation passes, a `qa-verifier` agent runs acceptance checks derived solely from the plan's objective and success criteria — with no knowledge of the implementation.

**How:** When both unit and E2E tests pass, `track_validation.sh` sets `validation_complete` and the `UserPromptSubmit` hook directs the model to invoke `/verify`. The `/verify` skill launches the `qa-verifier` agent with epistemic isolation: it receives only the objective and success criteria, never the implementation details or test code. The agent generates verification steps, runs them, and on all-pass calls `record_validation.sh` and `clear_approval.sh`.

**Why:** Two-tier tests prove the code works mechanically. Verification proves the objective is achieved. These are different claims. A test suite can pass while the user-facing outcome is broken (e.g., tests check string patterns but the actual feature doesn't render). Epistemic isolation ensures the verifier doesn't rubber-stamp the implementation by checking what the implementation does rather than what the objective requires.

**Enforcement scripts:** `scripts/track_validation.sh` (sets `validation_complete`), `scripts/record_validation.sh`, `/verify` skill, `qa-verifier` agent

### Phase 8: Completion

**What:** The human explicitly accepts or rejects the implementation, but the agent cannot complete unless the current plan objective is verified or the user manually bypasses the missing proof.

**How:** Two plugin commands:
- `/accept` — runs an acceptance preflight in `accept_outcome.sh`; if objective proof is missing it blocks on the first invocation and only the user can manually bypass by invoking `/accept` again
- `/reject` — calls `reject_outcome.sh`, clears approval markers, forces re-planning

**Why:** Explicit completion closes the feedback loop, but it must not become an agent-controlled bypass. The human can accept risk; the agent cannot. The first `/accept` is therefore a gate check, not a silent override.

**Enforcement scripts:** `scripts/accept_outcome.sh`, `scripts/reject_outcome.sh`

## Safety Layers

These protections operate across all phases, not within a specific one.

### Destructive Command Guard

`guard_destructive_bash.sh` intercepts every `Bash` tool call and blocks commands that would discard work: `git checkout --`, `git reset --hard`, `git clean -f`, `git push --force`, `git branch -D`, `git commit --amend`, `rm -rf` on tracked files, `--no-verify`, and pipe-to-shell patterns. Conditional checks (like `git checkout --`) only block when uncommitted changes exist.

**Why:** `settings.json` grants `Bash(*)` — all commands are allowed at the permission layer. This script is the sole safety gate. It's a denylist, not an allowlist, so legitimate commands flow through without friction while destructive ones are caught.

### SEP Commit Traceability

`sep_commit_check.sh` intercepts `git commit` commands and blocks them unless the commit message references a SEP issue (e.g., `SEP-003`). Projects with a `.sep-exempt` marker are bypassed.

**Why:** Every commit should trace back to a documented change proposal. This prevents orphan commits that nobody can explain six months later. SEPs (Software Evolution Proposals) provide the "why" for every change, making the git history navigable.

### Database Integrity Guard

`guard_destructive_bash.sh` blocks direct `sqlite3` write commands against `workflow.db`. The hook system's state must only be modified through the `state_read`/`state_write` API in `common.sh` or the designated hook scripts (`/approve`, `/skip-tests`, etc.). Direct SQL modifications bypass integrity guarantees and cause cascading state corruption.

**Why:** In multiple incidents, the agent patched workflow.db directly via `sqlite3` to bypass hook blocks — setting `tests_failed`, `tests_reviewed`, and approval markers without going through the proper workflow. This undermines the entire purpose of the enforcement system. The guard mechanically prevents this.

### Memory System

The `UserPromptSubmit` hook (`check_clear_approval_command.sh`) injects a `LEARNED PATTERNS` block into every prompt, surfacing the most important cross-project lessons from the `memories` table in `workflow.db`. Memories are ranked by `(correction_count * 2.0) + (attention_score * 3.0) + (access_count * 0.1)` and rendered in tiers: HOT (≥0.7 attention) shows full content, WARM (0.25–0.7) shows title only, COLD (<0.25) is omitted.

At session boundaries (`SessionEnd` hook), attention scores decay at type-specific rates: feedback 0.95, pattern/preference 0.98, task/note 0.85, gotcha 0.97. Each injection boosts attention by 0.15 (capped at 1.0). This creates a natural learning loop: corrections that keep being relevant strengthen; lessons that have been internalized fade.

**Why:** The agent has no durable learning mechanism — every session starts from zero. Without memory injection, the same corrections must be given repeatedly across sessions and projects. The memory system (SEPs 016–019, inspired by the Sift architecture) provides cross-project learning backed by SQLite FTS5 full-text search with Porter stemming and semantic enrichment (anticipated queries, concept tags).

### Pre-Commit Linting Pipeline

The global pre-commit hook (`git-hooks/pre-commit`) runs language-specific linters on staged files:
- **Python:** ruff (with flake8 fallback)
- **Shell:** shellcheck
- **JavaScript/TypeScript:** eslint (local then global fallback)
- **Go:** gofmt
- **Rust:** rustfmt

It also runs safety checks: hardcoded credential detection, dangerous `eval()`/`exec()` calls, `pickle.load()` usage, and shell script hygiene (shebang, `set -euo pipefail`).

The hook automatically bypasses repos with their own linting frameworks (`.pre-commit-config.yaml`, `.husky`, `lefthook.yml`, `lint-staged`) and chains to legitimate local `.git/hooks/pre-commit` scripts.

**Why:** Linting at commit time catches issues before they enter the repository. The bypass logic ensures this global hook doesn't fight with project-specific tooling.

### Commit Message Hygiene

The `commit-msg` hook runs `strip-claude-coauthor.sh` to remove "Co-Authored-By: Claude" from commit messages.

**Why:** Claude Code adds self-attribution by default. This hook strips it automatically so commit history reflects human authorship.

## Design Principles

### Mechanical enforcement over instruction compliance

Instructions in `CLAUDE.md` tell Claude what to do. Hooks in `settings.json` *make* it do those things. The instructions exist for Claude to understand the system; the hooks exist because understanding isn't compliance. Every rule that matters is backed by a script that blocks the tool call, not just text that asks nicely.

### Fail-closed by default

When in doubt, block. A missing approval marker means edits are blocked. A thin or weakly evidenced plan is rejected. A missing SEP reference means the commit is blocked. The system defaults to "no" and requires evidence to get to "yes." False positives (blocking legitimate work) are solved by escape hatches (`/approve`, `restore_approval.sh`); false negatives (letting bad work through) are much harder to fix after the fact.

### Human-in-the-loop at decision points

The system automates judgment-free checks (word counts, file existence, test runner detection) and routes judgment-required decisions to the human (plan approval, implementation acceptance). Claude never decides whether its own plan is good enough — the human does.

### Evidence over assumption

The epistemology rule in `CLAUDE.md` states: "Treat your training knowledge as an unreliable prior." The exploration requirement, plan evidence checks, and investigation protocol all serve this principle. Claude must cite what it found, not what it assumed. The validation section in plans makes this explicit: what is verified vs. what is assumed.

### Minimal friction for correct behavior

A model doing its job properly — exploring, planning, implementing within scope, testing — never hits a gate. The hooks only fire when steps are skipped. The system is designed so correct behavior is also the easiest path. Escape hatches exist for edge cases, but the default workflow should feel natural, not obstructive.

## Lifecycle Diagram

```
                                    ┌─────────────────────────────────────────────────────────┐
                                    │                    SAFETY LAYERS                         │
                                    │  guard_destructive_bash.sh  (every Bash call)           │
                                    │  sep_commit_check.sh        (every git commit)          │
                                    │  require_investigation_plan.sh (diagnostic questions)   │
                                    │  pre-commit hook            (every git commit)          │
                                    │  commit-msg hook            (every git commit)          │
                                    └─────────────────────────────────────────────────────────┘

User gives task
      │
      ▼
┌─────────────┐   First Action Protocol     ┌─────────────┐   validate_plan_quality.sh
│ 1. EXPLORE  │ ── docs/code exploration ─► │  2. PLAN    │ ──── quality checks ────►
│             │                              │             │   50+ words, sections,
│ Read docs   │                              │ Write plan  │   evidence, freshness
│ Read code   │                              │ to .md file │
│ Search      │                              │             │
└─────────────┘                              └─────────────┘
                                                                       │
                                                                       ▼
┌─────────────┐   require_plan_approval.sh  ┌─────────────┐        /approve
│ 4. IMPLEMENT│ ◄── scope-checked edits ──  │  3. REVIEW  │ ◄── human judgment ──
│             │    Only ## Scope files       │             │
│ Edit code   │    allowed                  │ Human reads  │
│ Write files │                             │ the plan     │
│ Run tools   │                             │              │
└─────────────┘                             └──────────────┘
      │
      │  track_dirty.sh (sets dirty flag)
      ▼
┌─────────────┐   track_validation.sh       ┌─────────────┐
│ 5. VALIDATE │ ──── two-tier tests ──────► │ 6. COMPLETE │
│             │    unit + E2E must pass      │             │
│ Run tests   │    to clear dirty flag       │ /accept  ──► done, approval cleared
│ Verify      │                              │ /reject  ──► re-plan from Phase 1
└─────────────┘                              └─────────────┘
```

## State Persistence

| Location | Scope | Survives sessions? |
|----------|-------|--------------------|
| `~/.claude/workflow.db` | All conversations (SQLite, WAL mode) | Yes |
| `~/.claude/plans/{token}/` | Per-conversation plan files | Yes |
| `~/.claude/shared-memory/` | Cross-project feedback memories | Yes |

All workflow state lives in `~/.claude/workflow.db`, scoped per conversation via `conversation_id`. The `sessions` table maps Claude Code's `session_id` to conversation tokens, enabling state to survive context compaction and session restarts. Memories (FTS5-indexed, with attention scoring and semantic enrichment) are global — not per-project.

## Further Reading

- **[README.md](README.md)** — Architecture, installation, script reference, customization
- **[USER_GUIDE.md](USER_GUIDE.md)** — When to use this, workflow examples, tips
- **[CLAUDE.md](CLAUDE.md)** — The instruction set loaded into Claude's context
