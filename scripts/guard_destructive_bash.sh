#!/bin/bash
# PreToolUse hook on Bash — denylist enforcement for destructive commands.
# settings.json grants Bash(*); this script is the sole safety gate.
source "$(dirname "$0")/common.sh"
init_hook

COMMAND=$(tool_input command)
[[ -z "$COMMAND" ]] && exit 0

# ── A. Full-command checks (before splitting) ──

# --no-verify: skipping hooks is never safe
if [[ "$COMMAND" == *--no-verify* ]]; then
    deny_tool "BLOCKED: --no-verify is not permitted.

Command: $COMMAND

Skipping git hooks is not allowed. Remove --no-verify and retry."
fi

# Pipe-to-shell: arbitrary remote code execution
if echo "$COMMAND" | grep -qE '(curl|wget)\s.*\|.*(bash|sh|zsh)'; then
    deny_tool "BLOCKED: Pipe-to-shell is not permitted.

Command: $COMMAND

Piping remote content to a shell is dangerous. Download the script first, review it, then run it."
fi

# ── B. Per-segment checks (split on &&, ||, |, ;) ──

check_segment() {
    local seg="$1"

    # B.1 Always-block patterns

    # git push --force / -f
    if echo "$seg" | grep -qE 'git\s+push\s.*--force|git\s+push\s.*\s-f\b'; then
        deny_tool "BLOCKED: git push --force is not permitted.

Command: $COMMAND

Force-pushing can overwrite remote history. Ask the user for explicit confirmation before proceeding."
    fi

    # git branch -D
    if echo "$seg" | grep -qE 'git\s+branch\s.*-D'; then
        deny_tool "BLOCKED: git branch -D is not permitted.

Command: $COMMAND

Force-deleting a branch can lose commits. Ask the user for explicit confirmation before proceeding."
    fi

    # git stash drop / git stash clear
    if echo "$seg" | grep -qE 'git\s+stash\s+(drop|clear)'; then
        deny_tool "BLOCKED: git stash drop/clear is not permitted.

Command: $COMMAND

Dropping stashes permanently destroys saved work. Ask the user for explicit confirmation before proceeding."
    fi

    # git commit --amend
    if echo "$seg" | grep -qE 'git\s+commit\s.*--amend'; then
        deny_tool "BLOCKED: git commit --amend is not permitted.

Command: $COMMAND

Amending rewrites the previous commit. Create a new commit instead, or ask the user for explicit confirmation."
    fi

    # B.2 Conditional patterns (only block when uncommitted changes exist)

    # git checkout -- / git checkout . / git reset --hard / git clean -f
    if echo "$seg" | grep -qE 'git\s+(checkout\s+--\s|checkout\s+\.\s*$|checkout\s+\.\s|reset\s+--hard|clean\s+-[a-zA-Z]*f)'; then
        AFFECTED_PATHS=$(echo "$seg" | sed -E 's/.*git\s+(checkout\s+--\s+|checkout\s+\.\s*|reset\s+--hard\s*|clean\s+-[a-zA-Z]*f\s*)//')

        if [[ -n "$AFFECTED_PATHS" && "$AFFECTED_PATHS" != "$seg" ]]; then
            STATUS=$(git status --porcelain -- $AFFECTED_PATHS 2>/dev/null)
        else
            STATUS=$(git status --porcelain 2>/dev/null)
        fi

        if [[ -n "$STATUS" ]]; then
            deny_tool "BLOCKED: Destructive command would discard uncommitted changes.

Command: $COMMAND

Uncommitted changes that would be lost:
$STATUS

Ask the user for explicit confirmation before proceeding."
        fi
    fi

    # git restore (not --staged) — discards working tree changes
    if echo "$seg" | grep -qE 'git\s+restore\s' && ! echo "$seg" | grep -qE 'git\s+restore\s+--staged'; then
        STATUS=$(git status --porcelain 2>/dev/null)
        if [[ -n "$STATUS" ]]; then
            deny_tool "BLOCKED: git restore would discard uncommitted changes.

Command: $COMMAND

Uncommitted changes that would be lost:
$STATUS

Ask the user for explicit confirmation before proceeding."
        fi
    fi

    # rm -r / rm -rf on git-tracked files
    if echo "$seg" | grep -qE 'rm\s+-[a-zA-Z]*r'; then
        RM_PATHS=$(echo "$seg" | sed -E 's/.*rm\s+-[a-zA-Z]+\s+//')

        if [[ -n "$RM_PATHS" ]]; then
            TRACKED=""
            for P in $RM_PATHS; do
                if git ls-files --error-unmatch "$P" &>/dev/null; then
                    TRACKED="${TRACKED}  $P\n"
                fi
            done

            if [[ -n "$TRACKED" ]]; then
                STATUS=$(git status --porcelain -- $RM_PATHS 2>/dev/null)
                deny_tool "BLOCKED: rm targets git-tracked files.

Command: $COMMAND

Git-tracked files that would be deleted:
$(echo -e "$TRACKED")
${STATUS:+Uncommitted changes:
$STATUS
}
Ask the user for explicit confirmation before proceeding."
            fi
        fi
    fi
}

# Split command on &&, ||, |, ; and check each segment
remaining="$COMMAND"
while [[ -n "$remaining" ]]; do
    if [[ "$remaining" =~ ^([^|&\;]*)(&&|\|\||[|;])(.*)$ ]]; then
        segment="${BASH_REMATCH[1]}"
        remaining="${BASH_REMATCH[3]}"
    else
        segment="$remaining"
        remaining=""
    fi
    check_segment "$segment"
done

# Non-destructive command — allow
exit 0
