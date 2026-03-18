#!/bin/bash
# Pre-sync hook for source_01 (bookstack_db)
# Runs mysqldump inside the bookstack_db container on the remote host,
# writing the dump to /tmp/bookstack.sql (on the remote).
#
# Available env vars (exported by app-backup.sh):
#   SRC_SSH_USER, SRC_SSH_HOST, SRC_SSH_PORT, SRC_SSH_IDENTITY  — effective SSH target
#   APP_SSH_USER, APP_SSH_HOST, APP_SSH_PORT, APP_SSH_IDENTITY  — app-level SSH defaults
#   AIRGAP_IP                                  — air-gap NIC bind address (use with ssh -b)
#   BOOKSTACK_DB_PASS                          — from bookstack/.env

set -euo pipefail

ssh -n ${APP_SSH_IDENTITY:+-i "${APP_SSH_IDENTITY}"} -b "${AIRGAP_IP}" -p "${APP_SSH_PORT}" "${APP_SSH_USER}@${APP_SSH_HOST}" \
    "/usr/bin/docker exec bookstack_db /usr/bin/mysqldump -p${BOOKSTACK_DB_PASS} bookstackapp > /tmp/bookstack.sql"
