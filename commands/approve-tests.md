---
description: Approve tests after review — unlocks production code editing
allowed-tools: Bash(~/.claude/scripts/*)
---

# Approve Tests

The user has reviewed the test files and confirms they are meaningful. Run:

1. Run `~/.claude/scripts/approve_tests.sh` via Bash to set the `tests_reviewed` marker
2. Confirm to the user that production code editing is now unlocked
3. Proceed with implementation (Phase B — make the tests pass)
