#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AGZ: Air-Gapped ZFS Backup Solution — One-Shot Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/gomiunik/agz/main/setup.sh | sudo bash
# for update re-run the same command; existing configs/apps will not be overwritten
# =============================================================================

REPO="https://raw.githubusercontent.com/gomiunik/agz/main"

# ---------------------------------------------------------------------------
# Color helpers (TTY-safe)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

info()  { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

# ---------------------------------------------------------------------------
# Error trap
# ---------------------------------------------------------------------------
trap 'error "Unexpected error on line ${LINENO}. Exiting."; exit 1' ERR

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    error "This script must be run as root (use sudo)."
    exit 1
fi

# ---------------------------------------------------------------------------
# TTY-safe prompt helper
# ask PROMPT DEFAULT
# Reads from /dev/tty when stdin is a pipe; falls back to DEFAULT in CI/headless
# ---------------------------------------------------------------------------
ask() {
    local prompt="$1"
    local default="${2:-N}"
    local reply

    if [ -t 0 ]; then
        read -r -p "$prompt" reply
    elif [ -e /dev/tty ]; then
        read -r -p "$prompt" reply < /dev/tty
    else
        reply="$default"
        echo "${prompt}${default} (non-interactive, using default)"
    fi

    echo "$reply"
}

# ---------------------------------------------------------------------------
# Banner + prerequisites
# ---------------------------------------------------------------------------
echo
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║        AIR-GAPPED ZFS BACKUP SOLUTION — INSTALLER           ║${RESET}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo
echo -e "${BOLD}Before continuing, verify the following prerequisites:${RESET}"
echo
echo "  1. Fresh Linux install recommended (Ubuntu 22.04+ or RHEL/CentOS/Rocky)"
echo "  2. ZFS pool 'backup-pool' must already exist"
echo "       zpool create backup-pool /dev/sdX"
echo "  3. Secondary NIC 'ens4' on 192.168.1.0/24 must exist"
echo "  4. Running as root (confirmed)"
echo
echo -e "${YELLOW}Press Enter to continue or Ctrl+C to abort.${RESET}"
ask "" ""

# =============================================================================
# Step 1 — Package installation
# =============================================================================
echo
info "Step 1/10 — Installing required packages"

if command -v apt-get &>/dev/null; then
    PKG_MGR="apt"
    apt-get update -qq
    apt-get install -y rsync openssh-client nginx zfsutils-linux
elif command -v dnf &>/dev/null; then
    PKG_MGR="rpm"
    dnf install -y rsync openssh-clients nginx
    warn "ZFS requires the OpenZFS repo on RPM systems. Skipping automatic ZFS install."
    warn "See: https://openzfs.github.io/openzfs-docs/Getting%20Started/RHEL-based%20distro/index.html"
elif command -v yum &>/dev/null; then
    PKG_MGR="rpm"
    yum install -y rsync openssh-clients nginx
    warn "ZFS requires the OpenZFS repo on RPM systems. Skipping automatic ZFS install."
    warn "See: https://openzfs.github.io/openzfs-docs/Getting%20Started/RHEL-based%20distro/index.html"
else
    warn "No supported package manager found (apt-get, dnf, yum). Skipping package install."
    PKG_MGR="unknown"
fi

if ! command -v zpool &>/dev/null; then
    warn "'zpool' not found after install. ZFS functionality will not work until it is installed."
fi

# =============================================================================
# Step 2 — SSH key generation
# =============================================================================
echo
info "Step 2/10 — SSH key setup"

SSH_KEY="/root/.ssh/agz_backup_ed25519"
mkdir -p /root/.ssh
chmod 700 /root/.ssh

if [ -f "$SSH_KEY" ]; then
    info "SSH key already exists at $SSH_KEY — skipping generation."
else
    ssh-keygen -t ed25519 -C "agz-backup@$(hostname)" -N "" -f "$SSH_KEY"
    info "SSH key generated at $SSH_KEY"
fi

PUBKEY=$(cat "${SSH_KEY}.pub")

echo
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Dedicated backup key generated: ${SSH_KEY}${RESET}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
echo
echo -e "${BOLD}  On each remote server, create the agz-backup service account${RESET}"
echo -e "${BOLD}  and install this key with SSH restrictions:${RESET}"
echo
echo -e "  ${CYAN}sudo useradd --system --no-create-home --shell /bin/bash agz-backup${RESET}"
echo -e "  ${CYAN}sudo mkdir -p /home/agz-backup/.ssh${RESET}"
echo -e "  ${CYAN}sudo chmod 700 /home/agz-backup/.ssh${RESET}"
echo -e "  ${CYAN}echo 'restrict,from=\"<AIRGAP_IP>\" ${PUBKEY}' | sudo tee /home/agz-backup/.ssh/authorized_keys${RESET}"
echo -e "  ${CYAN}sudo chmod 600 /home/agz-backup/.ssh/authorized_keys${RESET}"
echo -e "  ${CYAN}sudo chown -R agz-backup:agz-backup /home/agz-backup/.ssh${RESET}"
echo
echo -e "${BOLD}  Replace <AIRGAP_IP> with your backup server's air-gap NIC IP (e.g. 192.168.1.45).${RESET}"
echo -e "${BOLD}  See docs/remote-backup-user-setup.md for full setup instructions.${RESET}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
echo

reply=$(ask "Press Enter once you have configured the remote servers (or skip with Enter): " "")

# =============================================================================
# Step 3 — Download scripts from GitHub
# =============================================================================
echo
info "Step 3/10 — Downloading scripts from GitHub"

mkdir -p /usr/local/bin /usr/local/etc

# Parallel arrays: source paths and destination paths
SRCS=(
    "app-backup.sh"
    "generate_restore_script.sh"
    "maybe_generate_restore_script.sh"
    "airgap_link.sh"
    "pool-report.sh"
    "pool-scrub.sh"
    "pool-prune.sh"
    "backup_secrets.env"
)
DSTS=(
    "/usr/local/bin/app-backup.sh"
    "/usr/local/bin/generate-restore-script.sh"
    "/usr/local/bin/maybe-generate-restore-script.sh"
    "/usr/local/bin/airgap-link.sh"
    "/usr/local/bin/pool-report.sh"
    "/usr/local/bin/pool-scrub.sh"
    "/usr/local/bin/pool-prune.sh"
    "/usr/local/etc/backup-secrets.env"
)

for i in "${!SRCS[@]}"; do
    src="${SRCS[$i]}"
    dst="${DSTS[$i]}"
    url="${REPO}/${src}"
    if [ -f "$dst" ] && [ "$src" = "backup_secrets.env" ]; then
        info "  ${dst} already exists — skipping (delete to re-download)"
        continue
    fi
    info "  Downloading ${src} → ${dst}"
    curl -fsSL "$url" -o "$dst" || { error "Failed to download $url"; exit 1; }
done

# =============================================================================
# Step 4 — Set permissions
# =============================================================================
echo
info "Step 4/10 — Setting permissions"

chmod 755 \
    /usr/local/bin/app-backup.sh \
    /usr/local/bin/generate-restore-script.sh \
    /usr/local/bin/maybe-generate-restore-script.sh \
    /usr/local/bin/airgap-link.sh \
    /usr/local/bin/pool-report.sh \
    /usr/local/bin/pool-scrub.sh \
    /usr/local/bin/pool-prune.sh

chmod 600 /usr/local/etc/backup-secrets.env
mkdir -p /usr/local/etc/backup-apps

info "Permissions set."

# =============================================================================
# Step 5 — Deploy example apps (optional)
# =============================================================================
echo
reply=$(ask "Step 5/10 — Deploy example app configurations? (bookstack) [y/N]: " "N")

if [[ "$reply" =~ ^[Yy]$ ]]; then
    EXAMPLE_APPS=("bookstack")
    EXAMPLE_FILES=("app.conf" "source_01.conf" "source_02.conf" "pre_01.sh" "post_01.sh" "excludes_02.txt")

    for app in "${EXAMPLE_APPS[@]}"; do
        info "  Deploying example: $app"
        app_dir="/usr/local/etc/backup-apps/${app}"
        mkdir -p "$app_dir"

        for fname in "${EXAMPLE_FILES[@]}"; do
            url="${REPO}/backups/${app}/${fname}"
            dst="${app_dir}/${fname}"
            if [ -f "$dst" ]; then
                info "    ${dst} already exists — skipping (delete to re-download)"
                continue
            fi
            curl -fsSL "$url" -o "$dst" || { warn "  $fname not found for $app — skipping."; rm -f "$dst"; }
        done

        # chmod hook scripts
        for hook in "${app_dir}"/pre_*.sh "${app_dir}"/post_*.sh; do
            [ -f "$hook" ] && chmod 750 "$hook"
        done
    done

    warn "Remember to edit app.conf files with correct SSH hosts/users."
    warn "Create .env files in each app directory with required passwords."
else
    info "Skipping example app deployment."
fi

# =============================================================================
# Step 6 — Crontab setup (optional)
# =============================================================================
echo
reply=$(ask "Step 6/10 — Set up recommended crontab entries? [y/N]: " "N")

if [[ "$reply" =~ ^[Yy]$ ]]; then
    CRON_ENTRIES=(
        "0 2 * * * /usr/local/bin/app-backup.sh >> /var/log/backup.log 2>&1"
        "0 3 * * * /usr/local/bin/pool-prune.sh >> /var/log/zfs_prune.log 2>&1"
        "0 4 * * 0 /usr/local/bin/pool-scrub.sh >> /var/log/zfs_scrub.log 2>&1"
    )

    for entry in "${CRON_ENTRIES[@]}"; do
        if crontab -l 2>/dev/null | grep -qF "$entry"; then
            info "  Cron entry already exists, skipping: $entry"
        else
            ( crontab -l 2>/dev/null || true; echo "$entry" ) | crontab -
            info "  Added cron: $entry"
        fi
    done
else
    info "Skipping crontab setup."
fi

# =============================================================================
# Step 7 — Sudoers entry
# =============================================================================
echo
info "Step 7/10 — Writing sudoers entry"

IP_BIN=$(command -v ip 2>/dev/null || echo "/sbin/ip")
ZFS_BIN=$(command -v zfs 2>/dev/null || echo "/sbin/zfs")
MKDIR_BIN=$(command -v mkdir 2>/dev/null || echo "/bin/mkdir")

SUDOERS_TMP=$(mktemp)
cat > "$SUDOERS_TMP" <<EOF
# Air-Gapped ZFS Backup Solution — managed by setup.sh
root ALL=(ALL) NOPASSWD: ${IP_BIN} link set ens4 up
root ALL=(ALL) NOPASSWD: ${IP_BIN} link set ens4 down
root ALL=(ALL) NOPASSWD: ${IP_BIN} addr add 192.168.1.45/24 dev ens4
root ALL=(ALL) NOPASSWD: ${IP_BIN} addr flush dev ens4
root ALL=(ALL) NOPASSWD: ${ZFS_BIN} snapshot *
root ALL=(ALL) NOPASSWD: ${ZFS_BIN} destroy *
root ALL=(ALL) NOPASSWD: ${MKDIR_BIN} -p /backup-pool/*
EOF

if visudo -c -f "$SUDOERS_TMP" &>/dev/null; then
    install -m 0440 "$SUDOERS_TMP" /etc/sudoers.d/backup-solution
    info "Sudoers file written to /etc/sudoers.d/backup-solution"
else
    error "visudo validation failed for generated sudoers file. Skipping."
    warn "Temp file kept at: $SUDOERS_TMP"
fi
rm -f "$SUDOERS_TMP" 2>/dev/null || true

# =============================================================================
# Step 8 — Nginx setup
# =============================================================================
echo
info "Step 8/10 — Configuring nginx"

systemctl enable nginx && systemctl start nginx || warn "Failed to enable/start nginx — check systemd."

mkdir -p /var/www/html

# Detect nginx user
if id nginx &>/dev/null; then
    NGINX_USER="nginx"
elif id www-data &>/dev/null; then
    NGINX_USER="www-data"
else
    NGINX_USER=""
    warn "Could not detect nginx user (nginx/www-data). Skipping chown."
fi

[ -n "$NGINX_USER" ] && chown -R "${NGINX_USER}:" /var/www/html || true

# Write placeholder index only if missing
if [ ! -f /var/www/html/index.html ]; then
    cat > /var/www/html/index.html <<'EOF'
<!DOCTYPE html>
<html>
<head><title>Backup Server</title></head>
<body>
<h1>Air-Gapped ZFS Backup Server</h1>
<ul>
  <li><a href="backup-log.html">Backup Log</a></li>
  <li><a href="pool-health.html">ZFS Pool Health Report</a></li>
</ul>
</body>
</html>
EOF
    info "Placeholder /var/www/html/index.html written."
fi

# =============================================================================
# Step 9 — SSH login MOTD
# =============================================================================
echo
info "Step 9/10 — Writing login MOTD"

# Derive GitHub path from REPO URL (strip raw prefix)
# e.g. https://raw.githubusercontent.com/USER/REPO/main → USER/REPO
GITHUB_PATH=$(echo "$REPO" | sed 's|https://raw.githubusercontent.com/||; s|/main$||; s|/master$||')

MOTD_CONTENT="
╔══════════════════════════════════════════════════════════════╗
║            AIR-GAPPED ZFS BACKUP SERVER                     ║
╚══════════════════════════════════════════════════════════════╝

  Automated rsync + ZFS snapshot backup solution.

  Key paths:
    Scripts:   /usr/local/bin/app-backup.sh (and pool-*.sh)
    Apps:      /usr/local/etc/backup-apps/<app>/app.conf
    Secrets:   /usr/local/etc/backup-secrets.env
    Reports:   http://localhost/  (nginx)
    Logs:      /var/log/backup.log

  Quick commands:
    sudo /usr/local/bin/app-backup.sh          # run all apps
    sudo /usr/local/bin/app-backup.sh bookstack # run one app
    sudo /usr/local/bin/pool-report.sh         # ZFS health report

  Read more: https://github.com/${GITHUB_PATH}#readme
"

# Ubuntu/Debian with update-motd
if [ -d /etc/update-motd.d ]; then
    MOTD_SCRIPT="/etc/update-motd.d/99-backup-solution"
    printf '#!/bin/sh\ncat <<'"'"'MOTD'"'"'\n%s\nMOTD\n' "$MOTD_CONTENT" > "$MOTD_SCRIPT"
    chmod +x "$MOTD_SCRIPT"
    # Disable noisy uname motd if present
    [ -f /etc/update-motd.d/10-uname ] && chmod -x /etc/update-motd.d/10-uname || true
    info "MOTD script written to $MOTD_SCRIPT"
else
    printf '%s\n' "$MOTD_CONTENT" > /etc/motd
    info "MOTD written to /etc/motd"
fi

# =============================================================================
# Step 10 — Summary / next steps
# =============================================================================
echo
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║                  INSTALLATION COMPLETE                     ║${RESET}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo
echo -e "${BOLD}Step 10/10 — Next steps checklist:${RESET}"
echo
echo "  1. Edit secrets file:"
echo -e "       ${CYAN}nano /usr/local/etc/backup-secrets.env${RESET}"
echo
echo "  2. Edit app.conf files with correct SSH host/user for each app:"
echo -e "       ${CYAN}nano /usr/local/etc/backup-apps/<app>/app.conf${RESET}"
echo
echo "  3. Create .env files in each app directory with app passwords:"
echo -e "       ${CYAN}nano /usr/local/etc/backup-apps/<app>/.env${RESET}"
echo "       (chmod 600 after saving)"
echo
echo "  4. Create ZFS datasets for each app:"
echo -e "       ${CYAN}zfs create backup-pool/apps/bookstack${RESET}"
echo
echo "  5. Verify ZFS pool:"
echo -e "       ${CYAN}zpool status backup-pool${RESET}"
echo
echo "  6. Test air-gap NIC:"
echo -e "       ${CYAN}sudo /usr/local/bin/airgap-link.sh open${RESET}"
echo
echo "  7. Dry run a single app:"
echo -e "       ${CYAN}sudo /usr/local/bin/app-backup.sh bookstack${RESET}"
echo
echo "  8. View reports:"
echo -e "       ${CYAN}curl http://localhost/${RESET}"
echo
echo -e "${GREEN}${BOLD}Setup complete. Enjoy your air-gapped backups!${RESET}"
echo
