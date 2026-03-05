#!/bin/bash
# Validation recording with verified execution (SEP-022).
#
# Usage:
#   ~/.claude/scripts/record_validation.sh --command "pytest"
#       Verifies the command appears in validation_log, then clears dirty.
#
#   ~/.claude/scripts/record_validation.sh --manual "description"
#       Creates validate_pending marker (requires user /validate-confirm).
#       Does NOT clear dirty flag.
#
#   ~/.claude/scripts/record_validation.sh --force "description"
#       Legacy escape hatch — clears dirty unconditionally.
#
# Bare invocation (no flags) is BLOCKED.

PROJECT_HASH=$(pwd | shasum | cut -c1-12)
PERSIST_DIR="${CLAUDE_TEST_PERSIST_DIR:-${HOME}/.claude/state/${PROJECT_HASH}}"
mkdir -p "$PERSIST_DIR"

# Parse arguments
MODE=""
DESCRIPTION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)
            MODE="force"
            shift
            ;;
        --command)
            MODE="command"
            shift
            if [[ $# -gt 0 ]]; then
                DESCRIPTION="$1"
                shift
            fi
            ;;
        --manual)
            MODE="manual"
            shift
            if [[ $# -gt 0 ]]; then
                DESCRIPTION="$1"
                shift
            fi
            ;;
        *)
            # If no mode set yet, this is a bare positional arg
            if [[ -z "$MODE" ]]; then
                DESCRIPTION="$1"
            else
                DESCRIPTION="$1"
            fi
            shift
            ;;
    esac
done

DESCRIPTION="${DESCRIPTION:-manual validation}"

# Bare invocation (no flags) is blocked
if [[ -z "$MODE" ]]; then
    echo "BLOCKED: record_validation.sh requires a flag."
    echo ""
    echo "Usage:"
    echo "  --command \"pytest\"    Verify command ran, then clear dirty"
    echo "  --manual \"description\"  Set pending marker (user must confirm)"
    echo "  --force \"description\"   Legacy escape hatch (clears dirty)"
    exit 1
fi

# --command mode: verify the command actually ran (check validation_log)
if [[ "$MODE" == "command" ]]; then
    if [[ -z "$DESCRIPTION" ]]; then
        echo "BLOCKED: --command requires a command name argument."
        echo "Usage: record_validation.sh --command \"pytest\""
        exit 1
    fi

    LOG_FILE="${PERSIST_DIR}/validation_log"
    if [[ ! -f "$LOG_FILE" ]] || ! grep -q "$DESCRIPTION" "$LOG_FILE"; then
        echo "BLOCKED: Command '$DESCRIPTION' not found in validation_log."
        echo "Run the command first via Bash, then call record_validation.sh --command."
        exit 1
    fi

    # Command verified — clear dirty and record
    rm -f "${PERSIST_DIR}/dirty"
    echo "[COMMAND VERIFIED] $DESCRIPTION" > "${PERSIST_DIR}/validated"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [COMMAND VERIFIED] $DESCRIPTION" >> "${PERSIST_DIR}/validation_log"
    echo "Validation recorded (command verified): ${DESCRIPTION}. Dirty flag cleared."
    exit 0
fi

# --manual mode: set pending marker, do NOT clear dirty
if [[ "$MODE" == "manual" ]]; then
    echo "[MANUAL PENDING] $DESCRIPTION" > "${PERSIST_DIR}/validate_pending"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [MANUAL PENDING] $DESCRIPTION" >> "${PERSIST_DIR}/validation_log"
    echo "Manual validation pending: ${DESCRIPTION}."
    echo "User must run /validate-confirm to clear dirty flag."
    exit 0
fi

# --force mode: legacy escape hatch (unconditional clear)
if [[ "$MODE" == "force" ]]; then
    rm -f "${PERSIST_DIR}/dirty"
    echo "[MANUAL OVERRIDE] $DESCRIPTION" > "${PERSIST_DIR}/validated"
    echo "[MANUAL OVERRIDE] $DESCRIPTION" > "${PERSIST_DIR}/validated_unit"
    echo "[MANUAL OVERRIDE] $DESCRIPTION" > "${PERSIST_DIR}/validated_e2e"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [MANUAL OVERRIDE] $DESCRIPTION" >> "${PERSIST_DIR}/validation_log"
    echo "Validation recorded (MANUAL OVERRIDE): ${DESCRIPTION}. Dirty flag cleared."
    exit 0
fi
