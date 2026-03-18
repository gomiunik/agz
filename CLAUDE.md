# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Linux-based air-gapped backup solution using ZFS snapshots and rsync. Runs on a dedicated backup server with a secondary NIC for network isolation. Deployed files live in `/usr/local/bin/` and `/usr/local/etc/`.

## Deployed File Locations

| Local (dev) | Deployed (production) |
|---|---|
| `app-backup.sh` | `/usr/local/bin/app-backup.sh` |
| `generate_restore_script.sh` | `/usr/local/bin/generate-restore-script.sh` |
| `maybe_generate_restore_script.sh` | `/usr/local/bin/maybe-generate-restore-script.sh` |
| `airgap_link.sh` | `/usr/local/bin/airgap-link.sh` |
| `pool-report.sh` | `/usr/local/bin/pool-report.sh` |
| `pool-scrub.sh` | `/usr/local/bin/pool-scrub.sh` |
| `pool-prune.sh` | `/usr/local/bin/pool-prune.sh` |
| `backup_secrets.env` | `/usr/local/etc/backup-secrets.env` |
| `backups/<app>/` | `/usr/local/etc/backup-apps/<app>/` |

`app-backup.sh` expects its two helper scripts to live in the same directory as itself.

## Running the Scripts

```bash
# Run all apps
sudo /usr/local/bin/app-backup.sh

# Run a single app by folder name
sudo /usr/local/bin/app-backup.sh bookstack

# Run restore interactively for an app
sudo bash /usr/local/etc/backup-apps/bookstack/restore.sh

# Generate ZFS pool health report
sudo /usr/local/bin/pool-report.sh

# Trigger a ZFS scrub
sudo /usr/local/bin/pool-scrub.sh

# Prune snapshots older than 30 days
sudo /usr/local/bin/pool-prune.sh

# Manually control the air-gap interface
sudo /usr/local/bin/airgap-link.sh open
sudo /usr/local/bin/airgap-link.sh close
```

## Architecture

**app-backup.sh** is the orchestrator. Execution flow:
1. Source `backup-secrets.env` (global credentials, exported to subprocesses)
2. Open air-gap NIC via `airgap-link.sh open` + sleep 5
3. For each `<app>/` directory under `/usr/local/etc/backup-apps/` (alphabetical):
   - Skip if no `app.conf`; optionally filter by `$1` CLI argument
   - Source `app.conf`, then the app's `.env` if present (per-app secrets override globals)
   - For each `source_NN.conf` in order: run `pre_NN.sh` → rsync → `post_NN.sh`
   - Pre-sync failure blocks rsync and sets the app-failed flag; post-sync failure is a warning only
   - If all sources succeeded: `zfs snapshot`, then call `maybe_generate_restore_script.sh`
4. Close air-gap NIC via `airgap-link.sh close`
5. Write `/var/www/html/backup-log.html` (with per-app status table) and `index.html`

**Helper scripts** (must be co-located with `app-backup.sh`):
- `generate_restore_script.sh APP_DIR ZFS_DATASET APP_LABEL` — writes `restore.sh` into the app folder
- `maybe_generate_restore_script.sh APP_DIR ZFS_DATASET APP_LABEL` — skips generation if `restore.sh` already exists; delete it manually to force regeneration

Both helpers inherit `$LOG_FILE` from the parent process environment.

## App Folder Format

```
/usr/local/etc/backup-apps/<app>/
├── app.conf          # required: APP_NAME, SSH_USER/HOST/PORT, ZFS_DATASET, SKIP_SNAPSHOT; optional: SSH_IDENTITY
├── source_01.conf    # required: SOURCE_NAME, REMOTE_PATH, LOCAL_SUBDIR, EXCLUDES_FILE
├── source_02.conf    # optional: additional rsync source
├── pre_01.sh         # optional: pre-sync hook for source_01 (chmod 750, runs locally)
├── post_01.sh        # optional: post-sync hook for source_01 (chmod 750, runs locally)
├── excludes_02.txt   # optional: rsync --exclude-from list for source_02
├── .env              # optional: per-app secrets (chmod 600); overrides global secrets
└── restore.sh        # auto-generated after first successful run; delete to regenerate
```

Hook scripts run **locally** on the backup server and issue `ssh` calls explicitly. They receive SSH context as exported env vars: `APP_SSH_USER/HOST/PORT/IDENTITY` (from app.conf) and `SRC_SSH_USER/HOST/PORT/IDENTITY` (effective, may be overridden per source). `AIRGAP_IP` is also exported — hook scripts must pass `-b "$AIRGAP_IP"` to all `ssh` calls so connections originate from the air-gap NIC (required for the `from=` restriction in `authorized_keys`). All variables from global `backup-secrets.env` and the app `.env` are also available.

Source configs can override SSH with `SRC_SSH_USER`, `SRC_SSH_HOST`, `SRC_SSH_PORT`; unset fields fall back to app.conf values.

## Air-Gap Interface

`airgap-link.sh` brings up/down a dedicated secondary NIC (`ens4`, `192.168.1.45/24`). The backup subnet is `192.168.1.0/24`. Remote servers must be reachable on this subnet. The script includes `sleep 2` after `ip link set up` for Realtek NIC negotiation — do not remove it.

## ZFS Conventions

- Pool name: `backup-pool`
- Snapshot naming: `backup-pool@backup_YYYY-MM-DD_HHMM`
- Scrub schedule managed externally (cron). Snapshot pruning handled by `pool-prune.sh` (retain last 30 days; configure `RETAIN_DAYS` at top of script). Recommended cron: `0 3 * * * root /usr/local/bin/pool-prune.sh >> /var/log/zfs_prune.log 2>&1`
- `pool-report.sh` writes to `/var/www/html/pool-health.html`; this web directory is served by a local HTTP server for monitoring visibility

## Sudo Requirements

The backup user needs passwordless `sudo` for: `ip link`, `ip addr`, `zfs snapshot`, `zfs destroy`, `mkdir -p` on ZFS mount paths.

