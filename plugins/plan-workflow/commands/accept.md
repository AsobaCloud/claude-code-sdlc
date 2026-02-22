---
description: Accept completed implementation, commit changes, and update SEP issue
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---

# Accept Implementation

The user is accepting the completed implementation. Run the acceptance workflow:

1. Run `git status` to check for uncommitted changes
2. If there are changes to commit:
   a. Read the plan's objective from state (or the plan file) to determine the SEP reference
   b. If the project has no `.sep-exempt` file and no SEP exists, create one:
      - Source `~/.claude/scripts/sep_helpers.sh`
      - Create a SEP issue from the plan content
   c. Stage relevant files (not .env or credentials) and commit with message: "SEP-NNN: <summary>"
   d. Update the SEP issue's Commits section with the commit hash
   e. If the project has a GitHub remote, comment on the GitHub issue with the commit reference
3. Run `~/.claude/scripts/accept_outcome.sh` to clear approval state
4. Summarize what was implemented and committed
5. Confirm the acceptance to the user

Do NOT start any new work. Just confirm and stop.
