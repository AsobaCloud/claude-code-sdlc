---
description: Skip testing entirely — bypasses both TDD gate and test review gate
allowed-tools: Bash(~/.claude/scripts/*)
---

# Skip Tests

The user is bypassing testing for this task (e.g., config changes, CSS tweaks, documentation). Run:

1. Run `~/.claude/scripts/skip_tests.sh` via Bash to set both `tests_reviewed` and `tests_failed` markers
2. Confirm to the user that both the TDD gate and test review gate are bypassed
3. Proceed with implementation directly
