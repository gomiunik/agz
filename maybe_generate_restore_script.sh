#!/bin/bash
# maybe_generate_restore_script.sh — guarded wrapper around generate_restore_script.sh
# Deployed to: /usr/local/bin/maybe-generate-restore-script.sh
#
# Skips generation if restore.sh already exists (preserves user edits).
# Delete restore.sh manually to force regeneration.
# Inherits LOG_FILE from the calling process environment.
#
# Usage: maybe_generate_restore_script.sh APP_DIR ZFS_DATASET APP_LABEL

APP_DIR="$1"
ZFS_DATASET="$2"
APP_LABEL="$3"
RESTORE_SCRIPT="${APP_DIR}restore.sh"

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE:-/dev/null}"
}

if [[ -f "$RESTORE_SCRIPT" ]]; then
    log_msg "  [INFO] restore.sh already exists — skipping generation to preserve any local edits."
    log_msg "         Delete ${RESTORE_SCRIPT} to allow regeneration."
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${SCRIPT_DIR}/generate_restore_script.sh" "$APP_DIR" "$ZFS_DATASET" "$APP_LABEL"
