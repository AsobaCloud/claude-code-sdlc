---
name: tdd
description: Orchestrates the TDD workflow using epistemically isolated subagents. Use this skill IMMEDIATELY after plan approval for any code-change plan. When approve_plan.sh says "invoke /tdd", when the workflow state says "Next: Invoke /tdd", or when the user types /tdd — this skill runs the red-green-refactor cycle using isolated agents that cannot see the implementation plan.
---

# TDD Orchestration Skill

This skill runs the three-phase TDD cycle using isolated subagents. Each agent runs in its own context window and cannot see the other agents' reasoning or the implementation plan.

**You are the orchestrator.** You do NOT write tests or production code yourself. You launch agents and manage the workflow between them.

## Phase A: Red (Write Failing Tests)

### Step 1: Extract requirements from the approved plan

Read the plan file (path is in the workflow state injection). Extract ONLY:
- The **Objective** section (what the change should accomplish)
- The **Success Criteria** section (how to verify it works)
- The **Scope** section (which files will be modified — so the test writer knows what interfaces to read)

Do NOT extract:
- The Plan/implementation details
- The Justification
- The Validation section
- Any description of HOW the change will be implemented

### Step 2: Launch tdd-test-writer agent

Use the Agent tool with `subagent_type: "tdd-test-writer"`. The prompt MUST contain:
- The objective (what behavior is being added/changed)
- The success criteria (what "done" looks like)
- The scope file paths (so the agent can read existing interfaces)
- The project working directory

The prompt MUST NOT contain:
- Implementation approach or plan details
- Algorithmic strategy
- Which functions/methods will be created or modified
- Any content from the Plan section of the plan file

Example prompt structure:
```
You are writing tests for the following change:

**Objective:** <paste objective>
**Success criteria:** <paste criteria>

The following files are in scope for this change (read them to understand existing interfaces):
<list scope file paths>

Working directory: <project path>

Write tests that verify the objective is met. Run them to confirm they fail.
```

### Step 3: Review agent output

When the agent returns, it will have:
- Written test files
- Run them (they should have failed)

The `tests_failed` marker should now be set (via the PostToolUseFailure hook on the agent's Bash calls).

Present the test files to the user and explain what each test verifies. Then wait for the user to respond with `/approve-tests` or `/skip-tests`.

**Do NOT proceed to Phase B until the user responds.**

## Phase B: Green (Make Tests Pass)

### Step 4: Launch tdd-implementer agent

After `/approve-tests`, use the Agent tool with `subagent_type: "tdd-implementer"`. The prompt MUST contain:
- The test file paths (from the test-writer's output)
- The scope file paths (which production files to edit)
- The project working directory

The prompt MUST NOT contain:
- The implementation plan
- The test-writing rationale (why specific tests were chosen)
- The objective or success criteria (the tests ARE the specification now)

Example prompt structure:
```
Make the following failing tests pass:

**Test files:**
<list test file paths>

**Files you may edit (scope):**
<list scope file paths>

Working directory: <project path>

Read the test files to understand what behavior is expected. Implement the minimal code needed to make all tests pass. Run the tests after each change.
```

### Step 5: Verify all tests pass

When the implementer returns, verify that all tests pass. If any tests still fail, report the failures — do NOT attempt to fix them yourself.

## Phase C: Refactor (Optional)

### Step 6: Offer refactoring

Ask the user if they want a refactoring pass. If yes, launch `tdd-refactorer`:

```
All tests pass. Improve code quality while keeping tests green.

**Test files:** <list>
**Production files:** <list>
Working directory: <project path>
```

## After All Phases

Once Phase B (and optionally C) is complete, invoke `/verify` to run the VERIFYING phase:
1. Invoke `/verify` — this launches the `qa-verifier` agent with only the objective and success criteria
2. The agent generates verification steps, runs them, and reports pass/fail
3. On all-pass: the agent calls `record_validation.sh` and `clear_approval.sh`
4. On any failure: report failures to the user — do NOT proceed to `/accept`
5. Tell the user to `/accept` or `/reject` only after `/verify` completes successfully

## Critical Rules

1. **Never write tests or production code yourself.** Always delegate to agents.
2. **Never pass implementation details to the test-writer.** The whole point is epistemic isolation.
3. **Never pass test-writing rationale to the implementer.** Tests are the spec; the implementer shouldn't know why they were designed that way.
4. **Always wait for /approve-tests between Phase A and Phase B.** The user must review tests before implementation begins.
5. **If an agent fails or produces poor results, report to the user.** Do not attempt to fix it yourself — that breaks isolation.
