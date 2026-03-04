#!/bin/bash
# Escape hatch for non-standard validation (manual testing, curl, visual inspection, etc.)
# Usage: ~/.claude/scripts/record_validation.sh --force "description of validation performed"
# Requires --force flag to confirm manual validation bypass (SEP-005)

PROJECT_HASH=$(pwd | shasum | cut -c1-12)
PERSIST_DIR="${CLAUDE_TEST_PERSIST_DIR:-${HOME}/.claude/state/${PROJECT_HASH}}"
mkdir -p "$PERSIST_DIR"

# Check for --force flag
FORCE=false
DESCRIPTION=""
for arg in "$@"; do
    if [[ "$arg" == "--force" ]]; then
        FORCE=true
    else
        DESCRIPTION="$arg"
    fi
done
DESCRIPTION="${DESCRIPTION:-manual validation}"

if ! $FORCE; then
    echo "BLOCKED: Manual validation bypass requires --force flag."
    echo "Usage: ~/.claude/scripts/record_validation.sh --force \"description\""
    echo ""
    echo "Manual validation skips the two-tier requirement (unit + E2E tests)."
    echo "Use --force to confirm you understand this bypasses automated validation."
    exit 1
fi

# Clear dirty, set both tier markers (blanket override), record validation
rm -f "${PERSIST_DIR}/dirty"
echo "[MANUAL OVERRIDE] $DESCRIPTION" > "${PERSIST_DIR}/validated"
echo "[MANUAL OVERRIDE] $DESCRIPTION" > "${PERSIST_DIR}/validated_unit"
echo "[MANUAL OVERRIDE] $DESCRIPTION" > "${PERSIST_DIR}/validated_e2e"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [MANUAL OVERRIDE] $DESCRIPTION" >> "${PERSIST_DIR}/validation_log"

echo "Validation recorded (MANUAL OVERRIDE): ${DESCRIPTION}. Dirty flag cleared."
