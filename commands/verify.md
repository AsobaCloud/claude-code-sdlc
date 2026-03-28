---
description: Runs the VERIFYING phase using the qa-verifier agent. Use after two-tier test validation is complete (validation_complete marker is set). Invokes the /verify SKILL to orchestrate acceptance checks with epistemic isolation.
allowed-tools: Bash(~/.claude/scripts/*), Read, Agent
---

# Verify Command

This command runs the VERIFYING phase. It invokes the `/verify` SKILL, which launches the `qa-verifier` agent with only the plan objective and success criteria — not implementation details.

## When to use

Use `/verify` when:
- Two-tier test validation is complete (`validation_complete` marker is set)
- The workflow state shows `Phase: VERIFYING` and `Next: Invoke /verify`
- You need to record objective verification before calling `clear_approval.sh`

## What happens

1. The `/verify` SKILL reads the approved plan's Objective and Success Criteria
2. It launches the `qa-verifier` agent with only those two sections (epistemic isolation)
3. The agent generates at least one verification step per criterion and runs them
4. On all-pass: agent calls `record_validation.sh` and `clear_approval.sh`
5. On any failure: agent reports which criteria failed — do NOT proceed to `/accept`

## Invoke the verify SKILL

Follow the steps in `~/.claude/skills/verify/SKILL.md`.

## After completion

If all criteria passed and `clear_approval.sh` succeeded, tell the user to `/accept` or `/reject`.

If any criteria failed, report the failures. Do NOT call `clear_approval.sh`.
