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

## The Six Phases

Every task flows through six phases. Each phase has a gate — a hook script that blocks progress until the phase's requirements are met. The model experiences correct behavior as the path of least resistance.

```
 [1. Explore] ──► [2. Plan] ──► [3. Review] ──► [4. Implement] ──► [5. Validate] ──► [6. Complete]
      │                │              │                │                  │                │
  track_          validate_       /approve         require_plan_     track_dirty.sh    /accept
  exploration.sh  plan_quality.sh  (human gate)    approval.sh       track_            /reject
  (3+ reads)      (quality gate)                   (scope gate)      validation.sh
                                                                     (two-tier gate)
```

### Phase 1: Exploration

**What:** Claude must read at least 3 files before it can plan.

**How:** `track_exploration.sh` runs as a PreToolUse hook on `Read|Glob|Grep`. During planning mode, every read/search increments an exploration counter. `validate_plan_quality.sh` checks this counter — if fewer than 3 explorations occurred, the plan is rejected.

**Why:** Without this gate, Claude writes plans based on what it *assumes* your code looks like based on its training data. The exploration requirement forces it to actually look at your docs, your existing code, and the area it's about to change. Plans grounded in your actual codebase are qualitatively different from plans grounded in pattern-matched assumptions.

**Enforcement script:** `scripts/track_exploration.sh` (runs in <5ms, no-op outside plan mode)

### Phase 2: Planning

**What:** Claude must write a structured plan with required sections before any code changes are allowed.

**How:** `validate_plan_quality.sh` runs as a PreToolUse hook on `ExitPlanMode` and checks:

| Check | Requirement | Purpose |
|-------|-------------|---------|
| Plan file exists | `.md` in `~/.claude/plans/` or `.claude/plans/` | No plan = no approval |
| Plan freshness | < 30 minutes old | Prevents stale plans from prior sessions |
| Word count | >= 50 words | Blocks one-liner "plans" |
| Required sections | `## Objective` (10+ words), `## Scope` (file paths), `## Success Criteria` (10+ words), `## Justification` | Enforces structured thinking |
| Exploration evidence | Keywords like "existing", "found", "current" | Plan must describe what was discovered |
| Cross-reference | Plan mentions >= 2 files from exploration log | Proves the plan builds on actual exploration |
| File references | At least one file path in plan body | Plan must reference real files |

**Why:** A good plan is the highest-leverage artifact in the entire workflow. It forces Claude to articulate *what it found* during exploration and *how it will change things*. This is where training-data assumptions get caught — if the plan says "I'll create a new caching utility" but exploration showed you already have one, the human catches it at review. Without structured planning, Claude jumps straight to code and the human only discovers misalignment after implementation.

**Enforcement script:** `scripts/validate_plan_quality.sh`

### Phase 3: Human Review

**What:** The human reviews the plan and types `/approve` to unlock implementation.

**How:** `approve_plan.sh` runs as a PostToolUse hook on `ExitPlanMode`. It presents the plan to the human. The `/approve` plugin command sets the approval marker in persistent state. Until approval exists, all `Edit`, `Write`, and `NotebookEdit` calls are blocked by `require_plan_approval.sh`.

**Why:** The human is the domain expert. Claude proposes; the human decides. This is the only gate where a human judgment call is required — every other gate is automated. The plan gives the human a structured artifact to review: what will change, which files will be touched, what success looks like. This is dramatically more efficient than reviewing a completed implementation and saying "no, that's wrong, undo it all."

**Enforcement script:** `scripts/approve_plan.sh`, `plugins/plan-workflow/` (`/approve` command)

### Phase 4: Scoped Implementation

**What:** Claude can only edit files listed in the plan's `## Scope` section.

**How:** `require_plan_approval.sh` runs as a PreToolUse hook on `Edit|Write|NotebookEdit`. It checks two things: (1) does an approval marker exist, and (2) is the target file listed in the plan's `## Scope`. If either check fails, the edit is blocked.

**Why:** Scope enforcement prevents the most common failure mode of AI-assisted development: scope creep. Without it, Claude treats every task as an invitation to "improve" surrounding code — adding error handling nobody asked for, refactoring adjacent functions, updating docstrings on untouched files. Scope enforcement means "fix the bug in `auth.py`" results in changes to `auth.py` and nothing else.

**Enforcement script:** `scripts/require_plan_approval.sh`

### Phase 5: Validation

**What:** Code changes must be validated by both unit tests and E2E/integration tests before the task can complete.

**How:** Two scripts work together:
- `track_dirty.sh` (PostToolUse on `Edit|Write|NotebookEdit`) — sets a `dirty` flag whenever a non-exempt file is edited
- `track_validation.sh` (PostToolUse on `Bash`) — detects test runner commands and manages two-tier validation

The two-tier system (introduced in SEP-005) requires:
1. A **unit test** command must pass (npm test, pytest, go test, cargo test, etc.)
2. An **E2E/integration test** command must pass (commands containing e2e, integration, cypress, playwright, etc.)

Only when both tiers pass does the `dirty` flag clear. Running only one tier records progress but doesn't unlock completion.

**Why:** Code isn't done until it's tested. The dirty flag prevents Claude from declaring victory after writing code but before verifying it works. The two-tier requirement ensures both fine-grained correctness (unit) and system-level behavior (E2E) are verified. Without this, Claude's natural tendency is to write code, say "implementation complete," and move on — leaving the human to discover test failures later.

**Enforcement scripts:** `scripts/track_dirty.sh`, `scripts/track_validation.sh`

### Phase 6: Completion

**What:** The human explicitly accepts or rejects the implementation.

**How:** Two plugin commands:
- `/accept` — calls `accept_outcome.sh`, clears approval markers, signals satisfaction
- `/reject` — calls `reject_outcome.sh`, clears approval markers, forces re-planning

**Why:** Explicit completion closes the feedback loop. Without it, there's ambiguity about whether a task is done — Claude might keep making changes, or the human might forget to review. `/accept` and `/reject` create a clean boundary: the task is either done or it needs another cycle. This also resets the system state so the next task starts fresh.

**Enforcement scripts:** `scripts/accept_outcome.sh`, `scripts/reject_outcome.sh`

## Safety Layers

These protections operate across all phases, not within a specific one.

### Destructive Command Guard

`guard_destructive_bash.sh` intercepts every `Bash` tool call and blocks commands that would discard work: `git checkout --`, `git reset --hard`, `git clean -f`, `git push --force`, `git branch -D`, `git commit --amend`, `rm -rf` on tracked files, `--no-verify`, and pipe-to-shell patterns. Conditional checks (like `git checkout --`) only block when uncommitted changes exist.

**Why:** `settings.json` grants `Bash(*)` — all commands are allowed at the permission layer. This script is the sole safety gate. It's a denylist, not an allowlist, so legitimate commands flow through without friction while destructive ones are caught.

### SEP Commit Traceability

`sep_commit_check.sh` intercepts `git commit` commands and blocks them unless the commit message references a SEP issue (e.g., `SEP-003`). Projects with a `.sep-exempt` marker are bypassed.

**Why:** Every commit should trace back to a documented change proposal. This prevents orphan commits that nobody can explain six months later. SEPs (Software Evolution Proposals) provide the "why" for every change, making the git history navigable.

### Investigation Protocol

`require_investigation_plan.sh` activates when a diagnostic question is detected (errors, failures, "why is X broken"). It blocks all tools except `EnterPlanMode` until an investigation plan with `## Hypothesis` and `## Investigation Steps` is written and approved.

**Why:** Diagnostic questions are where Claude is most likely to confabulate. Without this gate, it will read one error message and confidently declare a root cause that's wrong. The investigation protocol forces systematic diagnosis: state a hypothesis, list investigation steps, gather evidence, then conclude. The user can type `/skip-investigation` to bypass this for simple questions.

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

When in doubt, block. A missing approval marker means edits are blocked. A missing exploration counter means the plan is rejected. A missing SEP reference means the commit is blocked. The system defaults to "no" and requires evidence to get to "yes." False positives (blocking legitimate work) are solved by escape hatches (`/approve`, `restore_approval.sh`); false negatives (letting bad work through) are much harder to fix after the fact.

### Human-in-the-loop at decision points

The system automates judgment-free checks (word counts, file existence, test runner detection) and routes judgment-required decisions to the human (plan approval, implementation acceptance). Claude never decides whether its own plan is good enough — the human does.

### Evidence over assumption

The epistemology rule in `CLAUDE.md` states: "Treat your training knowledge as an unreliable prior." The exploration requirement, plan cross-referencing, and investigation protocol all serve this principle. Claude must cite what it found, not what it assumed. The validation section in plans makes this explicit: what is verified vs. what is assumed.

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
┌─────────────┐    track_exploration.sh     ┌─────────────┐   validate_plan_quality.sh
│ 1. EXPLORE  │ ──────── 3+ reads ────────► │  2. PLAN    │ ──── quality checks ────►
│             │    Read, Glob, Grep          │             │   50+ words, sections,
│ Read docs   │    counted during            │ Write plan  │   cross-refs, freshness
│ Read code   │    planning mode             │ to .md file │
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
| `/tmp/.claude_hooks/{session_id}/` | Session-specific (planning, explore_count) | No |
| `~/.claude/state/{project_hash}/` | Project-specific (approval, scope, dirty, validated) | Yes |

On session start, `common.sh` hydrates session state from persistent state. This means approval, dirty flags, and validation progress carry across sessions automatically.

## Further Reading

- **[README.md](README.md)** — Architecture, installation, script reference, customization
- **[USER_GUIDE.md](USER_GUIDE.md)** — When to use this, workflow examples, tips
- **[CLAUDE.md](CLAUDE.md)** — The instruction set loaded into Claude's context
