# Rules

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

The Scope section is enforced: edits to files not listed will be BLOCKED.

Every plan MUST reference a SEP issue (e.g., "Implements SEP-003") unless the project
has a `.sep-exempt` marker. If no SEP exists, create one during planning using
`~/.claude/scripts/sep_helpers.sh`.

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

## Hook System - ENFORCED WORKFLOW

Hooks **BLOCK Edit/Write/NotebookEdit** until plan approval.
Hooks **BLOCK ExitPlanMode** if exploration or plan quality is insufficient.
Approval **persists across sessions** (project-scoped) until explicitly cleared.

### State Machine

```
[No Approval] ──EnterPlanMode──► [Planning] ──ExitPlanMode──► [Approved/Implementing]
      ^                                                              │
      │                                              clear_approval.sh (model runs when done)
      │                                                              │
      │                                              /accept, /reject, or EnterPlanMode
      │                                                              │
      └──────────────────────────────────────────────────────────────┘
```

Approval is set by:
- `ExitPlanMode` — user accepts the plan → editing unlocked immediately

Approval is cleared by:
- `~/.claude/scripts/clear_approval.sh` — model runs this after implementation is complete (HARD LOCK)
- `/accept` — user accepts the implementation (command)
- `/reject` — user rejects; must re-plan (command)
- `EnterPlanMode` — starting a new plan cycle clears the previous one

Approval is stored persistently per project directory. New sessions on the same
project automatically inherit existing approval state.

### The Workflow

1. `EnterPlanMode` → clears approval, enters planning, starts exploration tracking
2. Explore codebase: Read docs, Grep/Glob for related code (minimum 3 reads/searches)
3. Write substantive plan to plan file (50+ words, reference files found)
4. `ExitPlanMode` → validates exploration + plan quality → plan is approved → editing unlocked. Tell the user: "Plan approved. Starting implementation."
5. Implement ONLY the changes described in the plan. Every edit injects a scope reminder.
6. When implementation is complete, run `~/.claude/scripts/clear_approval.sh` to lock further edits. Then tell the user to review and type `/accept` or `/reject`.

### Emergency escape hatch

If approval is lost or needs manual restore (user runs from project directory):
```
~/.claude/scripts/restore_approval.sh
```

`/approve` also restores approval (**emergency use only** — never part of normal flow).
In the normal workflow, `ExitPlanMode` creates approval automatically via PreToolUse.

### What NOT To Do

- DO NOT bypass or work around the block
- DO NOT create marker files directly
- DO NOT assume approval has expired — it persists until cleared
- DO NOT make edits after running clear_approval.sh — you are locked out
- DO NOT make edits beyond what the approved plan describes
