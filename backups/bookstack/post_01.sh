#!/bin/bash
# Post-sync hook for source_01 (bookstack_db)
# Removes the temporary dump file from the remote host after rsync completes.
#
# Available env vars (exported by app-backup.sh):
#   SRC_SSH_USER, SRC_SSH_HOST, SRC_SSH_PORT, SRC_SSH_IDENTITY  — effective SSH target
#   APP_SSH_USER, APP_SSH_HOST, APP_SSH_PORT, APP_SSH_IDENTITY  — app-level SSH defaults
#   AIRGAP_IP                                  — air-gap NIC bind address (use with ssh -b)

set -euo pipefail

ssh -n ${APP_SSH_IDENTITY:+-i "${APP_SSH_IDENTITY}"} -b "${AIRGAP_IP}" -p "${APP_SSH_PORT}" "${APP_SSH_USER}@${APP_SSH_HOST}" \
    "rm -f /tmp/bookstack.sql"
