# Backup Server Setup (Ubuntu)

This guide covers preparing a fresh Ubuntu Server installation as the air-gapped ZFS backup server. It assumes the following hardware, but adapt disk identifiers and RAM limits as needed:

- **CPU/RAM:** any x86-64 with 12 GB RAM
- **SSD (250 GB):** OS + remaining space as ZFS special VDEV for metadata
- **HDDs (4× 1 TB):** ZFS RAIDZ1 data pool
- **NICs:** 1 Gb primary (`enp0s25`) + 2.5 Gb secondary or faster (`ens4`) for air-gap (change names to your configuration)

Primary NIC stays connected to the network and is used for management. You should configure strict access to your server on your firewall and server to not allow unnecessary access. The secondary NIC is used for the air-gap network and opens only when performing backups.

---

## 0. Ubuntu installation — SSD partitioning

During the Ubuntu Server installer, you will be asked to configure storage. Choose **custom/manual partitioning** (not the "entire disk" guided option) so you control the layout. **Do not enable LVM.**

### Why not LVM?

LVM adds a logical volume layer between the filesystem and the physical disk. On this server it provides no benefit and has real costs:

- ZFS manages its own redundancy, compression, snapshots, and volume allocation — it does not need or want another volume manager underneath it
- LVM on top of ZFS causes double-write-caching and alignment problems
- The only partition LVM would manage here is the OS root (`/`), which never needs to grow, shrink, or be snapshotted at the block level — Ubuntu's filesystem tools handle that fine without it
- Simpler is more recoverable: if the SSD fails, you reinstall Ubuntu on a new SSD and the ZFS pool on the HDDs is untouched

### Recommended partition layout

The SSD needs two things: the Ubuntu OS, and a chunk of free space left for you to partition into a ZFS special VDEV later (Section 3). A straightforward layout:

| Partition | Size | Type | Purpose |
|---|---|---|---|
| `sde1` | 1 MB | EFI System | GRUB/EFI boot |
| `sde2` | ~60 GB | ext4, mounted `/` | Ubuntu OS root |
| `sde3` | remainder (~185 GB) | **leave unformatted** | ZFS special VDEV (created in Section 3) |

> Leave partition 3 completely unformatted during the Ubuntu install — do not assign a filesystem or mount point to it. You will hand it to ZFS later.

In the Ubuntu installer's storage screen:
1. Select the SSD → **Use as Boot Device**
2. This automatically adds a 1 MB **EFI** partition
3. Add a 60 GB **ext4** partition, mount point `/`
4. Leave the rest **unallocated** — do not create a partition for it yet
5. Leave other disks unformatted (you will use them directly in ZFS)
6. Confirm and proceed with installation

---

## 1. Initial system update

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y nano rsync
```

---

## 2. SSH hardening

### Install your public key first

From your local machine, copy your public key to the server **before** disabling password authentication:

```bash
ssh-copy-id -p 22 <user>@<server-ip>
```

Or manually append the key content to `~/.ssh/authorized_keys` on the server.

### Change SSH port and disable password auth

```bash
sudo nano /etc/ssh/sshd_config
```

Set (uncomment if needed):

```
Port 2322
PubkeyAuthentication yes
PasswordAuthentication no
```

Restart SSH:

```bash
sudo systemctl restart sshd
```

> **Do not close your current session** until you have verified a new SSH session works on port 2322.

After the change, connect with:

```bash
ssh <user>@<server-ip> -p 2322
```

---

## 3. Partition the remaining SSD space

The SSD holds the Ubuntu OS install (typically ~60 GB used). The remaining space will become the ZFS special VDEV for pool metadata — this accelerates metadata-heavy workloads significantly.

Identify which disk has the OS:

```bash
lsblk
```

Look for the disk with a boot partition and the OS partition (e.g. `sde` with a 60 GB partition). Then create a new partition from the remaining free space:

```bash
sudo fdisk /dev/sde
```

In fdisk:
- `n` — new partition
- `p` — primary
- Accept the default partition number (should be `3`)
- Accept the default start sector (first free sector after existing partitions)
- Accept the default end sector (uses all remaining space)
- `w` — write and exit

Verify:

```bash
lsblk /dev/sde
```

You should now see a third partition (e.g. `sde3`).

---

## 4. Create the ZFS pool

### Identify disks by persistent ID

Always use `/dev/disk/by-id/` paths — never `/dev/sdX` names, which can change after a reboot.

List the 1 TB HDDs:

```bash
ls -l /dev/disk/by-id/ | grep -v "part"
```

Look for `ata-` prefixed entries pointing to your HDD devices.

Find the new SSD partition:

```bash
ls -l /dev/disk/by-id/ | grep "part3"
```

### Create the pool

Replace the disk IDs below with your actual values:

```bash
sudo zpool create -f -o ashift=12 backup-pool raidz1 \
  /dev/disk/by-id/ata-ST1000DM010-2EP102_Z9ADX6W0 \
  /dev/disk/by-id/ata-ST1000DM010-2EP102_ZN1VKVWD \
  /dev/disk/by-id/ata-ST1000DM010-2EP102_ZN1VL1FS \
  /dev/disk/by-id/ata-WDC_WD10EZRX-00A8LB0_WD-WMC1U6977345 \
  special /dev/disk/by-id/ata-CT240BX500SSD1_2515E9B62DB5-part3
```

**Options explained:**
- `ashift=12` — optimised for 4K-sector drives; set once at creation and cannot be changed
- `raidz1` — RAID-5 equivalent: tolerates 1 disk failure, usable capacity ≈ 3 TB
- `special` — the SSD partition stores ZFS metadata (directory entries, block pointers), reducing latency for small random I/O

Verify:

```bash
zpool status backup-pool
df -h /backup-pool
```

---

## 5. Tune ZFS ARC size

By default ZFS can consume most available RAM for its Adaptive Replacement Cache. With 12 GB RAM, cap it at 6 GB to leave headroom for the OS and rsync processes.

```bash
sudo nano /etc/modprobe.d/zfs.conf
```

Add:

```
options zfs zfs_arc_max=6442450944
```

`6442450944` = 6 × 1024³ bytes (6 GiB).

Apply and reboot:

```bash
sudo update-initramfs -u
sudo reboot
```

Verify after reboot:

```bash
cat /proc/spl/kstat/zfs/arcstats | grep c_max
```

---

## 6. Create ZFS datasets

Create a parent dataset for backup targets, then one dataset per application:

```bash
sudo zfs create backup-pool/apps
```

Add a dataset for each application you plan to back up, for example:

```bash
sudo zfs create backup-pool/apps/bookstack
sudo zfs create backup-pool/apps/nginx
sudo zfs create backup-pool/apps/nginx-proxy-manager
```

Each dataset gets its own mount point under `/backup-pool/apps/` and its own snapshot namespace.

---

## 7. Configure network interfaces

The server uses two NICs:
- `enp0s25` (1 Gb) — permanent management and internet access
- `ens4` (2.5 Gb) — air-gap NIC, brought up only during backup runs

Edit netplan (adjust IP settings of management interface to your network):

```bash
sudo nano /etc/netplan/50-cloud-init.yaml
```

Replace the contents with:

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    enp0s25:
      addresses:
        - "192.168.1.100/24"
      nameservers:
        addresses:
          - 1.1.1.1
        search: []
      routes:
        - to: "default"
          via: "192.168.1.1"
    # Air-gap NIC: brought up/down by airgap-link.sh during backup runs only
    ens4:
      dhcp4: no
      optional: true
```

Apply:

```bash
sudo netplan apply
```

> The `ens4` interface is intentionally left unconfigured here. The `airgap-link.sh` script assigns `192.168.1.45/24` to it at backup time and removes the address when done. The `optional: true` flag prevents boot delays if the NIC is not yet up.

---

## 8. Install the AGZ backup software

With the server prepared, run the one-shot installer:

```bash
curl -fsSL https://raw.githubusercontent.com/gomiunik/agz/main/setup.sh | sudo bash
```

The installer handles: package installation, SSH key generation, script deployment, permissions, sudoers, nginx, crontab, and MOTD. Follow the on-screen prompts.

After installation, see the [main README](../README.md) for configuring individual backup apps.

---

## Quick-reference: what you now have

| Component | Value |
|---|---|
| Primary NIC | `enp0s25` → `192.168.1.100/24` |
| Air-gap NIC | `ens4` → `192.168.1.45/24` (runtime only) |
| SSH port | `2322` |
| ZFS pool | `backup-pool` (RAIDZ1, ~3 TB usable) |
| ZFS metadata VDEV | SSD partition (`special`) |
| ZFS ARC cap | 6 GiB |
| Backup datasets | `/backup-pool/targets/<app>` |
