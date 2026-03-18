#!/bin/bash
# app-backup.sh — Folder-based application backup orchestrator
# Deployed to: /usr/local/bin/app-backup.sh
#
# Usage:
#   sudo /usr/local/bin/app-backup.sh              # run all apps
#   sudo /usr/local/bin/app-backup.sh bookstack    # run one app by folder name

GLOBAL_SECRETS="/usr/local/etc/backup-secrets.env"
APPS_DIR="/usr/local/etc/backup-apps"
LOG_FILE="/var/log/app-backup_$(date '+%Y-%m-%d').log"
APP_FILTER="${1:-}"

# --- Logging ---
log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}
export LOG_FILE   # inherited by helper subprocesses

# Path to sibling helper scripts (same dir as this script, both in dev and production)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# 1. Source global secrets
# ---------------------------------------------------------------------------
if [[ -f "$GLOBAL_SECRETS" ]]; then
    source <(tr -d '\r' < "$GLOBAL_SECRETS")
fi

# ---------------------------------------------------------------------------
# 2. Open air-gap
# ---------------------------------------------------------------------------
log_msg "--- STARTING APP BACKUP SEQUENCE ---"
/usr/local/bin/airgap-link.sh open
sleep 5

# Derive the air-gap bind IP from airgap-link.sh (strip the /prefix)
AIRGAP_IP=$(grep '^IP_ADDR=' /usr/local/bin/airgap-link.sh | cut -d= -f2 | tr -d '"' | cut -d/ -f1)
export AIRGAP_IP  # available to hook scripts for ssh -b binding

# Track per-app results for the HTML summary table
declare -a REPORT_LINES

# Allow empty globs without errors
shopt -s nullglob

# ---------------------------------------------------------------------------
# 3. Main loop — one iteration per app folder
# ---------------------------------------------------------------------------
for APP_DIR in "$APPS_DIR"/*/; do
    [[ -f "${APP_DIR}app.conf" ]] || continue

    APP_FOLDER=$(basename "$APP_DIR")

    # CLI filter: run only the requested app
    if [[ -n "$APP_FILTER" && "$APP_FOLDER" != "$APP_FILTER" ]]; then
        continue
    fi

    # Unset all app-level config vars to prevent bleed-through between apps
    unset APP_NAME APP_DESCRIPTION SSH_USER SSH_HOST SSH_PORT SSH_IDENTITY ZFS_DATASET SKIP_SNAPSHOT

    # Source app config (CRLF-safe)
    source <(tr -d '\r' < "${APP_DIR}app.conf")

    APP_LABEL="${APP_NAME:-$APP_FOLDER}"
    log_msg "### Processing app: ${APP_LABEL}"

    # Source per-app secrets (may override global secrets for same variable names)
    if [[ -f "${APP_DIR}.env" ]]; then
        source <(tr -d '\r' < "${APP_DIR}.env")
    fi

    APP_FAILED=0
    SOURCE_COUNT=0

    # -------------------------------------------------------------------------
    # 3a. Source loop — one iteration per source_NN.conf
    # -------------------------------------------------------------------------
    for SOURCE_CONF in "${APP_DIR}"source_*.conf; do
        [[ -f "$SOURCE_CONF" ]] || continue
        SOURCE_COUNT=$((SOURCE_COUNT + 1))

        # Extract numeric index (e.g. "01" from "source_01.conf")
        SRC_IDX=$(basename "$SOURCE_CONF" .conf)
        SRC_IDX="${SRC_IDX#source_}"

        # Unset source-level config vars to prevent bleed-through between sources
        unset SOURCE_NAME REMOTE_PATH LOCAL_SUBDIR EXCLUDES_FILE \
              SRC_SSH_USER SRC_SSH_HOST SRC_SSH_PORT SRC_SSH_IDENTITY

        # Source source config (CRLF-safe)
        source <(tr -d '\r' < "$SOURCE_CONF")

        # Resolve effective SSH (source-level overrides app-level)
        EFF_SSH_USER="${SRC_SSH_USER:-$SSH_USER}"
        EFF_SSH_HOST="${SRC_SSH_HOST:-$SSH_HOST}"
        EFF_SSH_PORT="${SRC_SSH_PORT:-${SSH_PORT:-22}}"
        EFF_SSH_IDENTITY="${SRC_SSH_IDENTITY:-${SSH_IDENTITY:-}}"

        log_msg "  Source ${SRC_IDX}: ${SOURCE_NAME:-unnamed} → ${EFF_SSH_USER}@${EFF_SSH_HOST}:${EFF_SSH_PORT}"

        # Export SSH context so hook scripts can use it without re-parsing configs
        export APP_SSH_USER="$SSH_USER"
        export APP_SSH_HOST="$SSH_HOST"
        export APP_SSH_PORT="${SSH_PORT:-22}"
        export APP_SSH_IDENTITY="${SSH_IDENTITY:-}"
        export SRC_SSH_USER="$EFF_SSH_USER"
        export SRC_SSH_HOST="$EFF_SSH_HOST"
        export SRC_SSH_PORT="$EFF_SSH_PORT"
        export SRC_SSH_IDENTITY="$EFF_SSH_IDENTITY"

        # Ensure local destination directory exists
        TARGET_DIR="/${ZFS_DATASET}"
        [[ -n "$LOCAL_SUBDIR" ]] && TARGET_DIR="/${ZFS_DATASET}/${LOCAL_SUBDIR}"
        sudo mkdir -p "$TARGET_DIR"

        # --- Pre-sync hook ---
        PRE_HOOK="${APP_DIR}pre_${SRC_IDX}.sh"
        if [[ -f "$PRE_HOOK" ]]; then
            if [[ -x "$PRE_HOOK" ]]; then
                log_msg "  Running pre_${SRC_IDX}.sh ..."
                "$PRE_HOOK"
                PRE_STATUS=$?
                if [[ $PRE_STATUS -ne 0 ]]; then
                    log_msg "  [ERROR] pre_${SRC_IDX}.sh exited ${PRE_STATUS}. Skipping rsync for source ${SRC_IDX}."
                    APP_FAILED=1
                    continue
                fi
            else
                log_msg "  [WARNING] pre_${SRC_IDX}.sh exists but is not executable — skipping hook."
            fi
        fi

        # --- rsync ---
        EXCLUDE_ARGS=()
        if [[ -n "$EXCLUDES_FILE" ]]; then
            # Treat relative paths as relative to the app folder
            [[ "$EXCLUDES_FILE" != /* ]] && EXCLUDES_FILE="${APP_DIR}${EXCLUDES_FILE}"
            if [[ -f "$EXCLUDES_FILE" ]]; then
                EXCLUDE_ARGS=("--exclude-from=${EXCLUDES_FILE}")
            else
                log_msg "  [INFO] EXCLUDES_FILE '${EXCLUDES_FILE}' not found — ignoring."
            fi
        fi

        SSH_IDENTITY_OPT=()
        [[ -n "$EFF_SSH_IDENTITY" ]] && SSH_IDENTITY_OPT=(-i "$EFF_SSH_IDENTITY")

        rsync -az --delete "${EXCLUDE_ARGS[@]}" \
            -e "ssh -p ${EFF_SSH_PORT} -b ${AIRGAP_IP} ${SSH_IDENTITY_OPT[*]:+${SSH_IDENTITY_OPT[*]}} -o ConnectTimeout=15" \
            "${EFF_SSH_USER}@${EFF_SSH_HOST}:${REMOTE_PATH}" \
            "$TARGET_DIR" < /dev/null
        RSYNC_STATUS=$?

        if [[ $RSYNC_STATUS -ne 0 ]]; then
            log_msg "  [ERROR] rsync failed (exit ${RSYNC_STATUS}) for source ${SRC_IDX} (${SOURCE_NAME:-unnamed})."
            APP_FAILED=1
            continue
        fi

        log_msg "  [SUCCESS] Source ${SRC_IDX} (${SOURCE_NAME:-unnamed}) synced."

        # --- Post-sync hook (failure = warning only; data is already safe) ---
        POST_HOOK="${APP_DIR}post_${SRC_IDX}.sh"
        if [[ -f "$POST_HOOK" ]]; then
            if [[ -x "$POST_HOOK" ]]; then
                log_msg "  Running post_${SRC_IDX}.sh ..."
                "$POST_HOOK"
                POST_STATUS=$?
                if [[ $POST_STATUS -ne 0 ]]; then
                    log_msg "  [WARNING] post_${SRC_IDX}.sh exited ${POST_STATUS}. Data already synced safely."
                fi
            else
                log_msg "  [WARNING] post_${SRC_IDX}.sh exists but is not executable — skipping hook."
            fi
        fi

    done  # end source loop

    # Warn and skip if no sources were found
    if [[ $SOURCE_COUNT -eq 0 ]]; then
        log_msg "  [WARNING] No source_*.conf files found in ${APP_DIR}. Skipping app."
        REPORT_LINES+=("${APP_LABEL}|SKIPPED")
        continue
    fi

    # --- Snapshot + restore script (only if every source succeeded) ---
    if [[ $APP_FAILED -eq 0 ]]; then
        if [[ "${SKIP_SNAPSHOT}" != "1" ]]; then
            SNAP_NAME="${ZFS_DATASET}@backup_$(date +%Y-%m-%d_%H%M)"
            log_msg "  Creating snapshot: ${SNAP_NAME}"
            sudo zfs snapshot "$SNAP_NAME"
            if [[ $? -eq 0 ]]; then
                log_msg "  [SUCCESS] Snapshot created."
            else
                log_msg "  [WARNING] zfs snapshot command failed."
            fi
        fi

        "${SCRIPT_DIR}/maybe_generate_restore_script.sh" "$APP_DIR" "$ZFS_DATASET" "$APP_LABEL"
        REPORT_LINES+=("${APP_LABEL}|SUCCESS")
    else
        log_msg "  [ERROR] App ${APP_LABEL} finished with failures — snapshot and restore.sh NOT updated."
        REPORT_LINES+=("${APP_LABEL}|FAILED")
    fi

done  # end app loop

# ---------------------------------------------------------------------------
# 4. Close air-gap
# ---------------------------------------------------------------------------
/usr/local/bin/airgap-link.sh close

# ---------------------------------------------------------------------------
# 5. Write HTML reports
# ---------------------------------------------------------------------------
log_msg "Updating web reports..."

{
    cat << 'HTML_HEAD'
<html>
<head>
    <style>
        body { font-family: monospace; background: #f4f4f4; padding: 20px; }
        h2 { margin-top: 30px; }
        table { border-collapse: collapse; margin-bottom: 20px; }
        th, td { border: 1px solid #ccc; padding: 6px 14px; text-align: left; }
        th { background: #ddd; }
        .success { color: green; font-weight: bold; }
        .failed  { color: red;   font-weight: bold; }
        .skipped { color: #888;  font-weight: bold; }
        pre { background: #fff; padding: 15px; border: 1px solid #ccc; overflow-x: auto; }
    </style>
</head>
<body>
    <h1>App Backup Log</h1>
HTML_HEAD

    echo "    <h2>Run Summary &mdash; $(date)</h2>"
    echo "    <table>"
    echo "      <tr><th>Application</th><th>Status</th></tr>"
    for line in "${REPORT_LINES[@]}"; do
        app_name="${line%%|*}"
        app_status="${line##*|}"
        css_class=$(echo "$app_status" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
        echo "      <tr><td>${app_name}</td><td class=\"${css_class}\">${app_status}</td></tr>"
    done
    echo "    </table>"
    echo "    <h2>Full Log</h2>"
    echo "    <pre>"
    cat "$LOG_FILE"
    echo "    </pre>"
    echo "</body>"
    echo "</html>"
} > /var/www/html/backup-log.html

cat << INDEX_EOF > /var/www/html/index.html
<html>
<head>
    <style>
        body { font-family: monospace; background: #f4f4f4; padding: 20px; }
        .button { display: inline-block; padding: 10px 20px; margin: 10px; background: #3498db; color: white; text-decoration: none; border-radius: 5px; }
        .card { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 5px rgba(0,0,0,0.1); }
    </style>
</head>
<body>
    <h1>Backup Status</h1>
    <p>Last Run: $(date)</p>
    <p>See <a class="button" href="pool-health.html">Pool Health</a></p>
    <p>See <a class="button" href="backup-log.html">Backup Log</a></p>
</body>
</html>
INDEX_EOF

log_msg "--- APP BACKUP SEQUENCE COMPLETE ---"
