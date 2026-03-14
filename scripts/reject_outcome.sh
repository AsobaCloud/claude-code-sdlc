#!/bin/bash
# Called by /reject command — clears approval after user rejects implementation

set -euo pipefail

source "$(dirname "$0")/common.sh"
init_persist_dir

clear_all_state

echo "Implementation rejected. Plan approval cleared. Provide feedback for re-planning."
