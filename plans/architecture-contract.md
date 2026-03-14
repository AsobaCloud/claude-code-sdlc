## Context

The hook system has suffered repeated architectural drift. Each adaptive fix (SEP-005 through SEP-007) introduced changes that conflicted with unstated assumptions. There is no single authoritative document describing the end-to-end contract. This plan creates it — describing the CORRECT DESIGN, not current bugs.

## Objective

Create `~/.claude/docs/ARCHITECTURE.md` — the single authoritative contract for the hook system's end-to-end workflow, state management, and concurrency model. Where the implementation doesn't yet match, a brief note flags the gap, but the contract itself specifies correct behavior. Implements SEP-003 (architecture contract).

## Scope

- /Users/shingi/.claude/docs/ARCHITECTURE.md
- /Users/shingi/.claude/CLAUDE.md

## Success Criteria

The document exists, covers all 11 sections (purpose, lifecycle, state storage, plan files, hook matrix, concurrency, self-modification, compaction recovery, concurrent sessions, failure loop prevention, implementation status), and is referenced from CLAUDE.md.

## Justification

Because `~/.claude/scripts/common.sh` shows that `init_persist_dir()` computes PERSIST_DIR from project hash + conversation token but this convention is not documented anywhere, and because `~/.claude/scripts/common.sh:newest_plan_file()` scans a shared `~/.claude/plans/` directory without conversation namespacing (creating a cross-conversation collision the user identified as a blocking problem), this plan creates an authoritative contract document. Because `~/.claude/CLAUDE.md` describes the hook workflow in prose but does not specify state storage contracts, concurrency rules, or the plan file ownership model, the document fills a gap that caused architectural drift across SEP-005 through SEP-007.

## Validation

**Sources consulted:**
- Every script in `~/.claude/scripts/` (read by Explore agent earlier in this conversation)
- Current `common.sh` (init_persist_dir, state helpers, plan resolution functions)
- SEP-005 through SEP-007 (conversation tokens, compaction recovery, PERSIST_DIR scoping)
- Current CLAUDE.md (workflow description, hook system section)

**Verified:** All hook scripts, state markers, and lifecycle transitions documented from actual code
**Note:** This is the contract document — it specifies correct behavior. An Implementation Status section flags where code doesn't yet match.

**External sources:**
1. Architecture Decision Records (ADR) convention (https://adr.github.io/) — establishes the practice of documenting architectural decisions and their rationale in a structured format
2. Design-by-contract methodology (Bertrand Meyer, "Object-Oriented Software Construction") — the principle that system components should have explicit preconditions, postconditions, and invariants documented as a contract

## Objective Verification

Verify the document exists and covers all required sections:
`grep -c '^## ' ~/.claude/docs/ARCHITECTURE.md && grep -l 'ARCHITECTURE.md' ~/.claude/CLAUDE.md`
