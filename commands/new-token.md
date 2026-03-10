---
description: Generate a new conversation token for session isolation
allowed-tools: Bash(~/.claude/scripts/*)
---

# Generate Conversation Token

Run `~/.claude/scripts/generate_token.sh` via Bash to generate a new conversation token.

This creates a unique token for this conversation, written to both MEMORY.md (survives compaction) and persistent state on disk. If you then need to use an existing plan, follow up with /approve.
