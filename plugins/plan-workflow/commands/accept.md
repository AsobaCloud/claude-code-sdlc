---
description: Accept completed implementation, commit changes, and update SEP issue
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
---

# Accept Implementation

The user is accepting the completed implementation. Run the acceptance workflow:

1. Run `git status` to check for uncommitted changes
2. Read and display validation evidence:
   a. Read the `validated` state file and `validation_log` from `~/.claude/state/{hash}/`
      (use: `PROJECT_HASH=$(pwd | shasum | cut -c1-12); cat ~/.claude/state/$PROJECT_HASH/validated; cat ~/.claude/state/$PROJECT_HASH/validation_log`)
   b. Read the plan's Success Criteria from state (or the plan file)
   c. Present both to the user so they can judge whether the criteria were actually met
3. If there are changes to commit:
   a. Read the plan's objective from state (or the plan file) to determine the SEP reference
   b. If the project has no `.sep-exempt` file and no SEP exists, create one:
      - Source `~/.claude/scripts/sep_helpers.sh`
      - Create a SEP issue from the plan content
   c. Stage relevant files (not .env or credentials) and commit with message: "SEP-NNN: <summary>"
   d. Update the SEP issue's Commits section with the commit hash
   e. If the project has a GitHub remote, comment on the GitHub issue with the commit reference
4. Run `~/.claude/scripts/accept_outcome.sh` to clear approval state
5. Summarize what was implemented and committed
6. Confirm the acceptance to the user

Do NOT start any new work. Just confirm and stop.
