#!/bin/bash
# Generate a new conversation token for session isolation (SEP-005)
# Usage: ~/.claude/scripts/generate_token.sh
source "$(dirname "$0")/common.sh"
init_persist_dir

TOKEN=$(generate_conversation_token)
echo "Conversation token generated: ${TOKEN}"
echo "Written to MEMORY.md and persistent state."
