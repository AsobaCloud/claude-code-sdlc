#!/bin/bash
# sep_helpers.sh — shared SEP (Schema Extension Proposal) issue tracking functions
# Source this in other scripts: source "$(dirname "$0")/sep_helpers.sh"

# ── sep_is_exempt: returns 0 if project has .sep-exempt marker ──
sep_is_exempt() {
    local project_root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
    [[ -f "${project_root}/.sep-exempt" ]]
}

# ── sep_dir: returns .sep/ path, creates if needed ──
sep_dir() {
    local project_root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
    local dir="${project_root}/.sep"
    mkdir -p "$dir"
    echo "$dir"
}

# ── sep_next_number: returns next sequential SEP number (zero-padded to 3 digits) ──
sep_next_number() {
    local dir
    dir=$(sep_dir)
    local max=0
    for f in "${dir}"/SEP-*.md; do
        [[ -f "$f" ]] || continue
        local num
        num=$(basename "$f" | grep -oE '[0-9]+' | head -1)
        # Strip leading zeros for arithmetic
        num=$((10#$num))
        if [[ "$num" -gt "$max" ]]; then
            max=$num
        fi
    done
    printf "%03d" $(( max + 1 ))
}

# ── sep_find_by_number: returns path to SEP-N.md ──
sep_find_by_number() {
    local num="$1"
    local dir
    dir=$(sep_dir)
    local padded
    padded=$(printf "%03d" "$((10#$num))")
    local path="${dir}/SEP-${padded}.md"
    if [[ -f "$path" ]]; then
        echo "$path"
    else
        echo ""
    fi
}

# ── sep_extract_ref: extracts SEP-NNN reference from text ──
sep_extract_ref() {
    local text="$1"
    echo "$text" | grep -oE 'SEP-[0-9]+' | head -1
}

# ── sep_create_local: creates local .sep/SEP-NNN.md file ──
# Args: title, summary, motivation, change, criteria
# Returns: SEP number (e.g., "001")
sep_create_local() {
    local title="$1"
    local summary="${2:-No summary provided.}"
    local motivation="${3:-No motivation provided.}"
    local change="${4:-No change description provided.}"
    local criteria="${5:-No acceptance criteria provided.}"

    local num
    num=$(sep_next_number)
    local dir
    dir=$(sep_dir)
    local project_name
    project_name=$(basename "${CLAUDE_PROJECT_DIR:-$(pwd)}")
    local today
    today=$(date +%Y-%m-%d)

    local path="${dir}/SEP-${num}.md"
    cat > "$path" <<EOF
# SEP-${num}: ${title}

**Status:** Open
**Created:** ${today}
**Project:** ${project_name}

## Summary
${summary}

## Motivation
${motivation}

## Proposed Change
${change}

## Acceptance Criteria
${criteria}

## Commits
<!-- Auto-updated by hook workflow -->
EOF

    echo "$num"
}

# ── sep_sync_to_github: creates GitHub issue if remote exists ──
# Args: sep_number
# Returns: GitHub issue URL (or empty if no remote)
sep_sync_to_github() {
    local num="$1"
    local padded
    padded=$(printf "%03d" "$((10#$num))")
    local sep_file
    sep_file=$(sep_find_by_number "$num")

    if [[ -z "$sep_file" || ! -f "$sep_file" ]]; then
        echo ""
        return 1
    fi

    # Check if gh CLI is available and project has a remote
    if ! command -v gh &>/dev/null; then
        echo ""
        return 1
    fi

    if ! git remote get-url origin &>/dev/null 2>&1; then
        echo ""
        return 1
    fi

    # Extract title and body from SEP file
    local title
    title=$(head -1 "$sep_file" | sed 's/^# //')
    local body
    body=$(cat "$sep_file")

    # Create GitHub issue
    local issue_url
    issue_url=$(gh issue create --title "$title" --body "$body" --label "sep" 2>/dev/null)

    if [[ -n "$issue_url" ]]; then
        # Store issue URL in the SEP file metadata
        sed -i '' "s|^\\*\\*Status:\\*\\*|**GitHub:** ${issue_url}\\
**Status:**|" "$sep_file" 2>/dev/null
        echo "$issue_url"
    else
        echo ""
    fi
}

# ── sep_add_commit: appends commit reference to SEP file ──
# Args: sep_number, commit_hash, message
sep_add_commit() {
    local num="$1"
    local commit_hash="$2"
    local message="$3"

    local sep_file
    sep_file=$(sep_find_by_number "$num")

    if [[ -z "$sep_file" || ! -f "$sep_file" ]]; then
        return 1
    fi

    local today
    today=$(date +%Y-%m-%d)
    local short_hash="${commit_hash:0:7}"

    # Append commit entry after the "## Commits" section marker
    sed -i '' "/^<!-- Auto-updated by hook workflow -->/a\\
- \`${short_hash}\` ${today}: ${message}" "$sep_file" 2>/dev/null

    # Update status to In Progress if still Open
    sed -i '' 's/^\*\*Status:\*\* Open/**Status:** In Progress/' "$sep_file" 2>/dev/null

    # Comment on GitHub issue if URL exists
    local github_url
    github_url=$(grep -oE 'https://github.com/[^ ]*' "$sep_file" 2>/dev/null | head -1)
    if [[ -n "$github_url" ]] && command -v gh &>/dev/null; then
        local issue_num
        issue_num=$(echo "$github_url" | grep -oE '[0-9]+$')
        if [[ -n "$issue_num" ]]; then
            gh issue comment "$issue_num" --body "Commit \`${short_hash}\`: ${message}" 2>/dev/null
        fi
    fi
}
