# Ubuntu Server on Flash

A single Bash script that installs a fully configured Ubuntu Server LTS onto a
USB flash drive, optimized for flash storage longevity.

## Features

- **F2FS root filesystem** with zstd:6 transparent compression — reduces writes
  and extends drive life while improving effective capacity
- **zram volatile directories** — `/tmp`, `/var/tmp`, `/var/log`, `/var/spool`,
  and `/var/cache` are backed by lzo-compressed zram block devices, keeping
  high-churn data entirely in RAM
- **Kernel and systemd tuning** — extended writeback intervals, volatile
  journald storage, masked APT/fsck/man-db timers, disabled core dumps
- **Portable UEFI boot** — GRUB installed with `--removable`, boots on any
  UEFI machine without touching NVRAM
- **Post-boot verification script** installed on the target to confirm all
  optimizations are active after first boot

## Requirements

The host machine running the script must be running Ubuntu/Debian with internet
access. Missing dependencies (`debootstrap`, `f2fs-tools`, `dosfstools`,
`gdisk`) are installed automatically.

The target USB drive must be at least **8 GB**.

## Usage

```
sudo ./ubuntu-server-on-flash.sh /dev/sdX [OPTIONS]
```

**Options:**

| Option | Default | Description |
|---|---|---|
| `--release NAME` | `noble` | Ubuntu release codename |
| `--mirror URL` | `http://archive.ubuntu.com/ubuntu` | APT mirror |
| `--hostname NAME` | `usbserver` | Target hostname |
| `--user NAME` | `admin` | Default username |
| `--password PASS` | `changeme` | Default password |
| `--efi-size SIZE` | `512M` | EFI partition size |
| `--no-swap` | *(swap enabled)* | Disable zram swap |

> **Warning:** The target device will be completely wiped. The script prompts
> for confirmation before making any changes.

## What the script does

1. **Preflight** — verifies root, prompts for confirmation, installs host dependencies
2. **Partition** — writes a GPT with a 512 M EFI partition and an F2FS root partition
3. **Filesystems** — formats EFI as FAT32 and root as F2FS with compression features enabled
4. **Mount** — mounts the root with `compress_algorithm=zstd:6,compress_extension=*`
5. **Debootstrap** — installs the Ubuntu base system
6. **Chroot configuration** — APT sources, kernel, GRUB, SSH, locale, user account, fstab, and networking via systemd-networkd
7. **Write-endurance optimizations** — see below
8. **Verification script** — installs `/usr/local/sbin/verify-usb-setup.sh` on the target
9. **Cleanup** — clears APT caches, unmounts, and syncs

## Write-endurance optimizations

| Area | Change |
|---|---|
| Volatile dirs | `/tmp`, `/var/tmp`, `/var/log`, `/var/spool`, `/var/cache` on lzo zram |
| Journald | `Storage=volatile`, 64 M cap, no forwarding to syslog |
| Writeback | `dirty_writeback_centisecs=6000`, `dirty_ratio=40` |
| Swap | zram (zstd, 50% RAM) or disabled via `--no-swap` |
| Timers masked | `apt-daily`, `apt-daily-upgrade`, `fstrim`, `man-db`, `e2scrub` |
| Core dumps | Disabled via sysctl and `systemd-coredump.socket` masked |
| F2FS | `f2fs-tune.service` sets `cp_interval=60`, disables iostat at boot |
| APT | All periodic tasks disabled via `apt.conf.d` |
| SSH host keys | Pre-generated at install time; key-generation service masked |

## Post-boot verification

After booting the installed drive, run:

```
sudo /usr/local/sbin/verify-usb-setup.sh
```

This checks filesystems, volatile directory mounts, journald storage, kernel
parameters, F2FS tuning, and masked services, and exits non-zero if any check
fails.

## First login

```
ssh admin@<ip>
```

You will be prompted to change your password on first login.
