# AGZ: Air-Gapped Backup Solution

Linux backup server using ZFS snapshots and rsync over an isolated secondary NIC.

---

## Requirements

- Bash 4+, rsync, openssh-client, zfsutils-linux (no additional packages needed)
- A ZFS pool named `backup-pool`
- A dedicated secondary NIC (`ens4`) on the `192.168.1.0/24` subnet
- An HTTP server serving `/var/www/html/` for the web dashboard

---

## Initial Server Setup

### 1. Deploy scripts

You can use the ```curl -fsSL https://raw.githubusercontent.com/gomiunik/agz/main/setup.sh | sudo bash``` method for a quick setup directly from the github repository, or copy the files manually:

```bash
# Scripts
sudo cp app-backup.sh              /usr/local/bin/app-backup.sh
sudo cp generate_restore_script.sh /usr/local/bin/generate-restore-script.sh
sudo cp maybe_generate_restore_script.sh /usr/local/bin/maybe-generate-restore-script.sh
sudo cp airgap_link.sh             /usr/local/bin/airgap-link.sh
sudo cp pool-report.sh             /usr/local/bin/pool-report.sh
sudo cp pool-scrub.sh              /usr/local/bin/pool-scrub.sh
sudo cp pool-prune.sh              /usr/local/bin/pool-prune.sh

# Global secrets
sudo cp backup_secrets.env         /usr/local/etc/backup-secrets.env
sudo chmod 600                     /usr/local/etc/backup-secrets.env

# Make everything executable
sudo chmod 750 /usr/local/bin/app-backup.sh \
               /usr/local/bin/generate-restore-script.sh \
               /usr/local/bin/maybe-generate-restore-script.sh \
               /usr/local/bin/airgap-link.sh \
               /usr/local/bin/pool-report.sh \
               /usr/local/bin/pool-scrub.sh \
               /usr/local/bin/pool-prune.sh
```

### 2. Create the apps directory

```bash
sudo mkdir -p /usr/local/etc/backup-apps
```

### 3. Configure passwordless sudo

Add to `/etc/sudoers.d/backup` (replace `backupuser` with the actual user):

```
backupuser ALL=(ALL) NOPASSWD: /usr/sbin/ip link set ens4 *
backupuser ALL=(ALL) NOPASSWD: /usr/sbin/ip addr *
backupuser ALL=(ALL) NOPASSWD: /usr/sbin/zfs snapshot *
backupuser ALL=(ALL) NOPASSWD: /usr/sbin/zfs clone *
backupuser ALL=(ALL) NOPASSWD: /usr/sbin/zfs rollback *
backupuser ALL=(ALL) NOPASSWD: /bin/mkdir -p /backup-pool/*
```

### 4. Set up SSH key access

The backup server must be able to SSH into each remote host without a password. if this hasn't been done by setup.sh:

```bash
ssh-keygen -t ed25519 -C "backup-server"
ssh-copy-id -p <port> <user>@<remote-host>
```

### 5. Schedule with cron

```bash
sudo crontab -e
```

```cron
# Run all app backups at 02:00 daily
0 2 * * * /usr/local/bin/app-backup.sh >> /var/log/app-backup-cron.log 2>&1

# Weekly ZFS scrub on Sunday at 03:00
0 3 * * 0 /usr/local/bin/pool-scrub.sh >> /var/log/pool-scrub.log 2>&1
```

---

## Adding a New App

### 1. Create the app folder

```bash
sudo mkdir -p /usr/local/etc/backup-apps/myapp
```

### 2. Write `app.conf`

```bash
APP_NAME="myapp"
APP_DESCRIPTION="My application"
SSH_USER="backupuser"
SSH_HOST="192.168.1.XX"
SSH_PORT="22"
ZFS_DATASET="backup-pool/apps/myapp"
SKIP_SNAPSHOT="0"   # set to 1 to disable ZFS snapshots
```

### 3. Create the ZFS dataset

The dataset must exist before the first run — `app-backup.sh` does **not** create it. If the dataset is missing, rsync will still run (into a plain directory) but the ZFS snapshot step will fail silently.

```bash
sudo zfs create backup-pool/apps/myapp
```

> If your app needs nested datasets or a custom mount point, create them now before proceeding.

### 4. Write `source_01.conf` (one file per rsync source)

```bash
SOURCE_NAME="myapp_data"
REMOTE_PATH="/var/lib/myapp"
LOCAL_SUBDIR="data"          # relative to ZFS dataset mount; leave empty for dataset root
EXCLUDES_FILE=""             # path to an rsync excludes file, or leave empty
# SSH overrides (leave commented to inherit from app.conf):
# SRC_SSH_USER=""
# SRC_SSH_HOST=""
# SRC_SSH_PORT=""
```

### 5. Write hook scripts (optional)

`pre_01.sh` — runs before rsync for source_01. Must exit 0 or rsync is skipped.

```bash
#!/bin/bash
# Available env: SRC_SSH_USER, SRC_SSH_HOST, SRC_SSH_PORT, APP_SSH_*, plus all secrets
ssh -n -p "${SRC_SSH_PORT}" "${SRC_SSH_USER}@${SRC_SSH_HOST}" \
    "your-remote-command-here"
```

`post_01.sh` — runs after a successful rsync. Non-zero exit is a warning only (data is safe).

```bash
#!/bin/bash
ssh -n -p "${SRC_SSH_PORT}" "${SRC_SSH_USER}@${SRC_SSH_HOST}" \
    "your-cleanup-command-here"
```

```bash
sudo chmod 750 /usr/local/etc/backup-apps/myapp/pre_01.sh \
               /usr/local/etc/backup-apps/myapp/post_01.sh
```

### 6. Add per-app secrets (if needed)

```bash
# /usr/local/etc/backup-apps/myapp/.env
export MYAPP_DB_PASS="secret"
```

```bash
sudo chmod 600 /usr/local/etc/backup-apps/myapp/.env
```

### 7. Test the app

```bash
# Syntax check
bash -n /usr/local/bin/app-backup.sh

# Dry run (opens air-gap, runs hooks and rsync, then closes)
sudo /usr/local/bin/app-backup.sh myapp

# Verify snapshot was created
zfs list -t snapshot -r backup-pool/apps/myapp

# Verify restore script was generated
ls -la /usr/local/etc/backup-apps/myapp/restore.sh
```

---

## Deploying the Bookstack Example

```bash
sudo cp -r backups/bookstack /usr/local/etc/backup-apps/bookstack
sudo chmod 750 /usr/local/etc/backup-apps/bookstack/pre_01.sh \
               /usr/local/etc/backup-apps/bookstack/post_01.sh
sudo chmod 600 /usr/local/etc/backup-apps/bookstack/.env

# Edit .env with the real password
sudo nano /usr/local/etc/backup-apps/bookstack/.env
```

---

## Daily Usage

```bash
# Run all apps
sudo /usr/local/bin/app-backup.sh

# Run a single app
sudo /usr/local/bin/app-backup.sh bookstack

# Check the web dashboard
curl http://localhost/

# Run restore interactively (see Restore Script section for full walkthrough)
sudo bash /usr/local/etc/backup-apps/bookstack/restore.sh

# Pool health report
sudo /usr/local/bin/pool-report.sh

# Manual air-gap control
sudo /usr/local/bin/airgap-link.sh open
sudo /usr/local/bin/airgap-link.sh close
```

---

## File Reference

### `app.conf` keys

| Key | Required | Description |
|---|---|---|
| `APP_NAME` | yes | Identifier shown in logs and web report |
| `APP_DESCRIPTION` | no | Human-readable description |
| `SSH_USER` | yes | Default SSH user for all sources |
| `SSH_HOST` | yes | Default SSH host for all sources |
| `SSH_PORT` | yes | Default SSH port (usually `22`) |
| `ZFS_DATASET` | yes | ZFS dataset path, e.g. `backup-pool/apps/myapp` |
| `SKIP_SNAPSHOT` | no | Set to `1` to skip ZFS snapshot |

### `source_NN.conf` keys

| Key | Required | Description |
|---|---|---|
| `SOURCE_NAME` | yes | Label for this source in logs |
| `REMOTE_PATH` | yes | Absolute path on the remote host to rsync |
| `LOCAL_SUBDIR` | no | Subdirectory under the ZFS dataset mount; empty = dataset root |
| `EXCLUDES_FILE` | no | Path to an rsync excludes file (relative to app folder or absolute) |
| `SRC_SSH_USER` | no | Overrides `SSH_USER` from app.conf for this source |
| `SRC_SSH_HOST` | no | Overrides `SSH_HOST` from app.conf for this source |
| `SRC_SSH_PORT` | no | Overrides `SSH_PORT` from app.conf for this source |

### Environment variables available in hook scripts

| Variable | Source |
|---|---|
| `APP_SSH_USER/HOST/PORT` | app.conf values |
| `SRC_SSH_USER/HOST/PORT` | Effective values (source override or app fallback) |
| All `export`ed vars from `backup-secrets.env` | Global secrets |
| All `export`ed vars from `.env` | Per-app secrets |

---

## Restore Script

`restore.sh` is auto-generated into each app folder after the first successful backup. It reads `app.conf` and `source_*.conf` at runtime, so SSH details and remote paths stay current without regeneration.

It will **not** be overwritten on subsequent runs — delete it manually to force regeneration (e.g. if the restore logic itself changes after an upgrade).

```bash
# Run restore interactively
sudo bash /usr/local/etc/backup-apps/bookstack/restore.sh

# Force regeneration
sudo rm /usr/local/etc/backup-apps/bookstack/restore.sh
sudo /usr/local/bin/app-backup.sh bookstack
```

### Interactive flow

**1. Select a snapshot**

The script lists all snapshots for the app's ZFS dataset, newest first:

```
Available snapshots (newest first):
  [1] backup-pool/apps/bookstack@backup_2026-03-17_0200
  [2] backup-pool/apps/bookstack@backup_2026-03-16_0200
  [3] backup-pool/apps/bookstack@backup_2026-03-15_0200
  [Enter] Latest: backup-pool/apps/bookstack@backup_2026-03-17_0200

Select snapshot (1-3, or Enter for latest):
```

Press Enter to use the most recent snapshot without typing.

**2. Confirm**

```
Selected       : backup-pool/apps/bookstack@backup_2026-03-17_0200
Restore target : remote hosts defined in /usr/local/etc/backup-apps/bookstack/source_*.conf

[WARNING] This will overwrite live data on the remote host(s) with snapshot data.

Are you sure? (y/N):
```

**3. Restore runs**

The script opens the air-gap NIC, then for each `source_NN.conf`:

- Locates the snapshot data via the ZFS `.zfs/snapshot/` magic directory — a built-in read-only view that requires no clone and leaves no residual data
- Pushes it back to the remote host with rsync (source and destination are swapped from a normal backup run):

```
Source (local) : /<dataset>/.zfs/snapshot/<snap>/<LOCAL_SUBDIR>/
Destination    : <SSH_USER>@<SSH_HOST>:<REMOTE_PATH>
```

For `.sql` destinations, the script additionally prompts for an optional import command to run on the remote (e.g. loading the dump back into a database container):

```
Detected .sql destination. Run a remote import command?
  Example: docker exec -i <container> mysql -u <user> -p<password> <db> < /tmp/bookstack.sql
  Enter import command (or Enter to skip):
```

The air-gap NIC is closed after all sources are processed.

### Customising the rsync command

The restore rsync is plainly commented in `restore.sh`:

```bash
# ---------------------------------------------------------------------------
# RSYNC RESTORE
# Source (local) : ${SNAP_DIR}/   (read-only snapshot contents, no cleanup needed)
# Destination    : ${EFF_SSH_USER}@${EFF_SSH_HOST}:${REMOTE_PATH}
#
# Adjust ssh options or add --exclude flags below as needed for your environment.
# ---------------------------------------------------------------------------
rsync -az \
    -e "ssh -p ${EFF_SSH_PORT} -o ConnectTimeout=15" \
    "${SNAP_DIR}/" \
    "${EFF_SSH_USER}@${EFF_SSH_HOST}:${REMOTE_PATH}"
```

Edit that block directly to add `--exclude`, change rsync flags, or redirect to a different host. Since the script is not overwritten automatically, edits are preserved across backup runs.
