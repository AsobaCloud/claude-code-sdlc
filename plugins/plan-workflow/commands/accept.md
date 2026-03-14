---
description: Accept completed implementation, commit changes, and update SEP issue
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---

# Accept Implementation

The user is accepting the completed implementation. Run the acceptance workflow:

1. Run `~/.claude/scripts/accept_outcome.sh --preflight` before doing anything else.
   If it blocks, stop there and relay the exact reason to the user. Do NOT commit and do NOT clear state.
2. Run `git status` to check for uncommitted changes.
3. Read and display validation evidence:
   a. Read the `validated`, `objective_verified_evidence`, and `validation_log` state files from `~/.claude/state/{hash}/`
   b. Read the plan's `## Success Criteria` and `## Objective Verification`
   c. Present both so the user can see what proof exists for the accepted objective
4. If there are changes to commit:
   a. Read the plan's objective from state (or the plan file) to determine the SEP reference
   b. If the project has no `.sep-exempt` file and no SEP exists, create one:
      - Source `~/.claude/scripts/sep_helpers.sh`
      - Create a SEP issue from the plan content
   c. Stage relevant files (not .env or credentials) and commit with message: "SEP-NNN: <summary>"
   d. Update the SEP issue's Commits section with the commit hash
   e. If the project has a GitHub remote, comment on the GitHub issue with the commit reference
5. Run `~/.claude/scripts/accept_outcome.sh --finalize` to clear approval state
6. Summarize what was implemented and committed
7. Confirm the acceptance to the user

Do NOT start any new work. Just confirm and stop.
