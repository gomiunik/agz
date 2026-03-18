#!/bin/bash
# pool-prune.sh — Delete ZFS snapshots older than RETAIN_DAYS from backup-pool.
#
# Deployed: /usr/local/bin/pool-prune.sh
# Typical cron (daily at 03:00):
#   0 3 * * * root /usr/local/bin/pool-prune.sh >> /var/log/zfs_prune.log 2>&1

POOL_NAME="backup-pool"
RETAIN_DAYS=30
LOG_FILE="/var/log/zfs_prune.log"
CUTOFF=$(date -d "${RETAIN_DAYS} days ago" +%s)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

log "Starting snapshot prune for ${POOL_NAME} (retain last ${RETAIN_DAYS} days)."

DELETED=0
ERRORS=0

while IFS= read -r SNAP; do
    # Extract the timestamp portion after the '@backup_' prefix (YYYY-MM-DD_HHMM)
    SNAP_TAG="${SNAP##*@backup_}"

    # Parse: replace the underscore between date and time with a space for date(1)
    SNAP_DATE="${SNAP_TAG:0:10} ${SNAP_TAG:11:2}:${SNAP_TAG:13:2}"
    SNAP_EPOCH=$(date -d "$SNAP_DATE" +%s 2>/dev/null)

    if [[ -z "$SNAP_EPOCH" ]]; then
        log "  [SKIP] Cannot parse date from snapshot name: ${SNAP}"
        continue
    fi

    if [[ "$SNAP_EPOCH" -lt "$CUTOFF" ]]; then
        log "  [DESTROY] ${SNAP}  (created ~${SNAP_DATE})"
        if sudo zfs destroy "$SNAP"; then
            (( DELETED++ ))
        else
            log "  [ERROR] Failed to destroy ${SNAP}"
            (( ERRORS++ ))
        fi
    fi
done < <(zfs list -t snapshot -H -o name -s creation -r "$POOL_NAME" 2>/dev/null)

log "Done. Destroyed: ${DELETED}  Errors: ${ERRORS}"
