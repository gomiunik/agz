# Secure Backup User Setup on Remote Linux Server

This guide sets up a dedicated `agz-backup` service account on a remote server for use with the air-gapped backup system. It avoids using personal user accounts for automated backup connections.

## Why a Dedicated Service Account

- **Least privilege** — reads only what backup needs, nothing else
- **Blast radius containment** — a compromised key only affects backup reads on that server
- **Audit separation** — backup activity is clearly distinct from human activity in logs
- **Service continuity** — backup is independent of any personal account lifecycle
- **Future-proof** — default ACLs propagate read access to newly created files automatically

---

## Step 1 — On the backup server: generate a dedicated keypair

```bash
# Generate ED25519 key (no passphrase — required for unattended automation)
sudo ssh-keygen -t ed25519 -C "agz-backup@backup-server" \
  -f /root/.ssh/agz_backup_ed25519 -N ""

# Show public key — copy this for Step 3
sudo cat /root/.ssh/agz_backup_ed25519.pub
```

---

## Step 2 — On the remote server: create the service account

```bash
# Create user: no password, no home directory content
# Shell must be a real shell (e.g. /bin/bash) so rsync and remote commands work.
# Interactive login is blocked by 'restrict' in authorized_keys (no PTY), not by nologin.
sudo useradd --system --no-create-home --shell /bin/bash agz-backup

# Verify
id agz-backup
```

---

## Step 3 — On the remote server: install the public key with restrictions

```bash
# Create SSH directory
sudo mkdir -p /home/agz-backup/.ssh
sudo chmod 700 /home/agz-backup/.ssh

# Add public key with restrictions (paste your pubkey from Step 1)
# 'restrict' disables PTY, port-forwarding, X11, and agent-forwarding in one keyword
# 'from=' restricts key use to connections from the backup server's air-gap IP only
echo 'restrict,from="192.168.1.45" ssh-ed25519 AAAA...your-pubkey... agz-backup@backup-server' \
  | sudo tee /home/agz-backup/.ssh/authorized_keys

sudo chmod 600 /home/agz-backup/.ssh/authorized_keys
sudo chown -R agz-backup:agz-backup /home/agz-backup/.ssh
```

> The `from="192.168.1.45"` restriction means the key is useless even if stolen — it will only authenticate from the backup server's air-gap NIC IP.

---

## Step 4 — On the remote server: grant read access to backup data

First, identify who owns the directories that need to be backed up:

```bash
ls -la /opt/your-app/
```

### Option A — Add to owning group (if data has a sensible group and is not root group)

```bash
# Add agz-backup to the group that owns the data — do NOT use the root group
sudo usermod -aG <owning-group> agz-backup
```

### Option B — Use ACLs (if data is root-owned with no useful group)

```bash
# Install the acl package if not already present (Debian/Ubuntu)
sudo apt install acl

# Install the acl package if not already present (RHEL/CentOS/Rocky)
sudo dnf install acl

# Grant read access to existing files recursively
sudo setfacl -R -m u:agz-backup:rX /opt/your-app

# Grant read access to future files automatically (default ACL)
sudo setfacl -R -d -m u:agz-backup:rX /opt/your-app
```

> The `-d` (default) ACL flag is key for future-proofing — any new files or directories created under the path will automatically inherit read access for `agz-backup`.

### Option C — Grant Docker access (if pre/post hooks run docker commands)

If hook scripts need to run `docker exec` or `docker ps` on the remote server, add `agz-backup` to the `docker` group:

```bash
sudo usermod -aG docker agz-backup
```

> **Security note:** The `docker` group grants effective root-equivalent access on the host, since containers can be used to escape to root. Only add `agz-backup` to the docker group on servers where hook scripts genuinely require it.

---

## Step 5 — On the backup server: configure SSH to use the new key

Add to `/root/.ssh/config`:

```
Host <remote-server-ip>
    User agz-backup
    IdentityFile /root/.ssh/agz_backup_ed25519
    IdentitiesOnly yes
    Port 22
```

---

## Step 6 — Update the app's `app.conf`

```bash
SSH_USER="agz-backup"
SSH_IDENTITY="/root/.ssh/agz_backup_ed25519"
```

`SSH_IDENTITY` is exported by `app-backup.sh` as `SRC_SSH_IDENTITY` so hook scripts can reference it directly:

```bash
# In a pre_NN.sh or post_NN.sh hook:
# -b "$AIRGAP_IP" binds the source IP to the air-gap NIC, required for the from= key restriction
ssh -n ${SRC_SSH_IDENTITY:+-i "${SRC_SSH_IDENTITY}"} -b "$AIRGAP_IP" -p "$SRC_SSH_PORT" "$SRC_SSH_USER@$SRC_SSH_HOST" "your command"
```

Per-source overrides are also supported via `SRC_SSH_IDENTITY` in `source_NN.conf`.

---

## Step 7 — Test the connection

```bash
# From the backup server — nologin shell exits immediately, this is expected
sudo ssh -i /root/.ssh/agz_backup_ed25519 -p 22 \
  -b 192.168.1.45 agz-backup@<remote-server-ip> "ls /opt/your-app/"

# Test rsync dry-run
sudo rsync -az --dry-run \
  -e "ssh -p 22 -b 192.168.1.45 -i /root/.ssh/agz_backup_ed25519" \
  agz-backup@<remote-server-ip>:/opt/your-app/ /tmp/app-test/
```

---

## Security Properties Summary

| Concern | How it's addressed |
|---|---|
| Least privilege | `agz-backup` reads only group/ACL-permitted data |
| Future new files | `setfacl -d` propagates access to new files automatically |
| Key theft scope | `from=` IP restriction makes stolen key unusable |
| No interactive access | `restrict` in `authorized_keys` + nologin shell |
| Audit separation | Dedicated user produces separate log entries |
| Service continuity | Independent from any personal account lifecycle |
