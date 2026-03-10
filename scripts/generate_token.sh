#!/bin/bash
# Generate a new conversation token for session isolation (SEP-005)
# Usage: ~/.claude/scripts/generate_token.sh
source "$(dirname "$0")/common.sh"

PROJECT_HASH=$(pwd | shasum | cut -c1-12)
PERSIST_DIR="${CLAUDE_TEST_PERSIST_DIR:-${HOME}/.claude/state/${PROJECT_HASH}}"
mkdir -p "$PERSIST_DIR"

TOKEN=$(generate_conversation_token)
echo "Conversation token generated: ${TOKEN}"
echo "Written to MEMORY.md and persistent state."
