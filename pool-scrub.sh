#!/bin/bash

POOL_NAME="backup-pool"
LOG_FILE="/var/log/zfs_scrub.log"

echo "[$(date)] Starting ZFS Scrub for $POOL_NAME..." >> $LOG_FILE

# Start the scrub
zpool scrub $POOL_NAME

# Note: Scrubbing happens in the background.
# The script finishes instantly, but the HDDs will be busy for a few hours.
echo "[$(date)] Scrub initiated. Check 'zpool status' for progress." >> $LOG_FILE