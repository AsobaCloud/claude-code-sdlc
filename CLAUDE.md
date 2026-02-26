# Rules

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

The Scope section is enforced: edits to files not listed will be BLOCKED.

Every plan MUST reference a SEP issue (e.g., "Implements SEP-003") unless the project
has a `.sep-exempt` marker. If no SEP exists, create one during planning via Bash:
`~/.claude/scripts/sep_create.sh "title" "summary" "motivation" "change" "criteria"`

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
Approval is stored **persistently per project directory** (pwd hash). It survives
session changes, context compaction, and new sessions — no session-scoped state exists.

### The Workflow

1. `EnterPlanMode` → clears previous approval, enters planning
2. Explore codebase: Read docs, Grep/Glob for related code
3. Write substantive plan to plan file (50+ words, all required sections)
4. `ExitPlanMode` → validates plan quality → approved → editing unlocked
5. Implement ONLY the changes described in the plan
6. Run `~/.claude/scripts/clear_approval.sh` → locked. Tell user to `/accept` or `/reject`.

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
