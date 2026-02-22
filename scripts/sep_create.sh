#!/bin/bash
# Create a SEP (Schema Extension Proposal) issue file
# Usage: ~/.claude/scripts/sep_create.sh "title" ["summary"] ["motivation"] ["change"] ["criteria"]
# Returns: SEP number on stdout

source "$(dirname "$0")/sep_helpers.sh"

if [[ -z "$1" ]]; then
    echo "Usage: sep_create.sh \"title\" [\"summary\"] [\"motivation\"] [\"change\"] [\"criteria\"]" >&2
    exit 1
fi

NUM=$(sep_create_local "$1" "$2" "$3" "$4" "$5")
echo "Created SEP-${NUM} in $(sep_dir)/SEP-${NUM}.md"
