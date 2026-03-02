#!/usr/bin/env bash
# =============================================================================
# Ubuntu Server LTS → USB Flash Drive Installer (Single Script)
# F2FS + zstd:6 compression, write-endurance optimized
# =============================================================================
# Usage:
#   sudo ./ubuntu-usb-install.sh /dev/sdX [OPTIONS]
#
# Options:
#   --release NAME    Ubuntu release codename (default: noble)
#   --mirror URL      APT mirror (default: http://archive.ubuntu.com/ubuntu)
#   --hostname NAME   Target hostname (default: usbserver)
#   --user NAME       Default username (default: admin)
#   --password PASS   Default password (default: changeme)
#   --efi-size SIZE   EFI partition size (default: 512M)
#   --no-swap         Do not configure zram swap
#   --help            Show this help
# =============================================================================
set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
RELEASE="noble"
MIRROR="http://archive.ubuntu.com/ubuntu"
MOUNTPOINT="/mnt/usb-target"
EFI_SIZE="512M"
HOSTNAME_TARGET="usbserver"
DEFAULT_USER="admin"
DEFAULT_PASS="changeme"
ENABLE_SWAP=true

# Partition device paths (set after parsing args)
TARGET=""
PART_EFI=""
PART_ROOT=""

# ── Colors / logging ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[FATAL]${NC} $*" >&2; exit 1; }
step()    { echo -e "\n${GREEN}${BOLD}━━━ Step $1: $2 ━━━${NC}"; }
chroot_info() { echo -e "  ${CYAN}[chroot]${NC} $*"; }
chroot_ok()   { echo -e "  ${GREEN}[chroot]${NC} $*"; }

# =============================================================================
# Argument parsing
# =============================================================================
usage() {
    sed -n '/^# Usage:/,/^# =====/p' "$0" | grep -v '====' | sed 's/^# //'
    exit 0
}

parse_args() {
    [[ $# -eq 0 ]] && usage

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --release)    RELEASE="$2";        shift 2 ;;
            --mirror)     MIRROR="$2";         shift 2 ;;
            --hostname)   HOSTNAME_TARGET="$2"; shift 2 ;;
            --user)       DEFAULT_USER="$2";   shift 2 ;;
            --password)   DEFAULT_PASS="$2";   shift 2 ;;
            --efi-size)   EFI_SIZE="$2";       shift 2 ;;
            --no-swap)    ENABLE_SWAP=false;   shift   ;;
            --help|-h)    usage ;;
            -*)           die "Unknown option: $1 (see --help)" ;;
            *)
                [[ -z "$TARGET" ]] && TARGET="$1" || die "Unexpected argument: $1"
                shift
                ;;
        esac
    done

    [[ -n "$TARGET" ]] || die "No target device specified. Usage: $0 /dev/sdX [OPTIONS]"
    [[ -b "$TARGET" ]] || die "$TARGET is not a block device."

    # Determine partition naming (nvme-style vs sd-style)
    if [[ "$TARGET" =~ [0-9]$ ]]; then
        PART_EFI="${TARGET}p1"
        PART_ROOT="${TARGET}p2"
    else
        PART_EFI="${TARGET}1"
        PART_ROOT="${TARGET}2"
    fi
}

# =============================================================================
# Cleanup / teardown
# =============================================================================
cleanup_mounts() {
    info "Cleaning up mounts..."
    local dirs=(
        "$MOUNTPOINT/boot/efi"
        "$MOUNTPOINT/dev/pts"
        "$MOUNTPOINT/dev"
        "$MOUNTPOINT/proc"
        "$MOUNTPOINT/sys"
        "$MOUNTPOINT/run"
        "$MOUNTPOINT"
    )
    for d in "${dirs[@]}"; do
        mountpoint -q "$d" 2>/dev/null && umount -lf "$d" 2>/dev/null || true
    done
}

on_error() {
    echo -e "\n${RED}ERROR on line $1. Cleaning up...${NC}" >&2
    cleanup_mounts 2>/dev/null
    exit 1
}

# =============================================================================
# Step 1: Preflight checks & host dependencies
# =============================================================================
preflight() {
    step 1 "Preflight checks and host dependencies"

    [[ $EUID -eq 0 ]] || die "This script must be run as root."

    # Safety confirmation
    echo ""
    echo -e "${RED}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  WARNING: ALL DATA ON ${TARGET} WILL BE PERMANENTLY DESTROYED     ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINT "$TARGET" 2>/dev/null || true
    echo ""
    echo -e "  Release  : ${BOLD}$RELEASE${NC}"
    echo -e "  Hostname : ${BOLD}$HOSTNAME_TARGET${NC}"
    echo -e "  User     : ${BOLD}$DEFAULT_USER${NC}"
    echo -e "  Swap     : ${BOLD}$(${ENABLE_SWAP} && echo 'zram (enabled)' || echo 'DISABLED')${NC}"
    echo ""
    read -rp "Type YES in all caps to continue: " CONFIRM
    [[ "$CONFIRM" == "YES" ]] || die "Aborted by user."

    # Install host dependencies
    local DEPS=(debootstrap f2fs-tools dosfstools gdisk parted)
    local MISSING=()
    for pkg in "${DEPS[@]}"; do
        dpkg -s "$pkg" &>/dev/null || MISSING+=("$pkg")
    done
    if [[ ${#MISSING[@]} -gt 0 ]]; then
        info "Installing host packages: ${MISSING[*]}"
        apt-get update -qq
        apt-get install -y -qq "${MISSING[@]}"
    fi
    ok "Host dependencies ready."
}

# =============================================================================
# Step 2: Partition the target drive
# =============================================================================
partition_drive() {
    step 2 "Partitioning $TARGET (GPT: ${EFI_SIZE} EFI + F2FS root)"

    # Unmount anything currently on the target
    for mp in $(findmnt -rn -o TARGET -S "${TARGET}"* 2>/dev/null || true); do
        umount -f "$mp" 2>/dev/null || true
    done

    wipefs -af "$TARGET"
    sgdisk --zap-all "$TARGET"
    sgdisk -n "1:0:+${EFI_SIZE}" -t 1:ef00 -c 1:"EFI"    "$TARGET"
    sgdisk -n 2:0:0              -t 2:8300 -c 2:"rootfs"  "$TARGET"
    partprobe "$TARGET"
    sleep 2

    [[ -b "$PART_EFI"  ]] || die "EFI partition $PART_EFI not found."
    [[ -b "$PART_ROOT" ]] || die "Root partition $PART_ROOT not found."
    ok "Partitions created: EFI=$PART_EFI  Root=$PART_ROOT"
}

# =============================================================================
# Step 3: Create filesystems
# =============================================================================
create_filesystems() {
    step 3 "Creating filesystems"

    info "Formatting EFI (FAT32)..."
    mkfs.vfat -F 32 -n EFI "$PART_EFI"

    info "Formatting root (F2FS with compression feature)..."
    mkfs.f2fs -f \
        -O extra_attr,inode_checksum,sb_checksum,compression \
        -C utf8 \
        -l rootfs \
        "$PART_ROOT"

    ok "Filesystems created."
}

# =============================================================================
# Step 4: Mount with compression active
# =============================================================================
mount_target() {
    step 4 "Mounting F2FS with zstd:6 compression"

    cleanup_mounts 2>/dev/null
    mkdir -p "$MOUNTPOINT"

    local F2FS_OPTS="compress_algorithm=zstd:6,compress_extension=*,compress_chksum,gc_merge,atgc,lazytime,noatime"
    mount -t f2fs -o "$F2FS_OPTS" "$PART_ROOT" "$MOUNTPOINT"

    mkdir -p "$MOUNTPOINT/boot/efi"
    mount -t vfat "$PART_EFI" "$MOUNTPOINT/boot/efi"

    ok "Mounted — ALL writes from here on are compressed on disk."
}

# =============================================================================
# Step 5: Debootstrap
# =============================================================================
run_debootstrap() {
    step 5 "Bootstrapping Ubuntu $RELEASE (this takes several minutes)"

    debootstrap --arch=amd64 "$RELEASE" "$MOUNTPOINT" "$MIRROR"

    ok "Base system installed with compression."
}

# =============================================================================
# Step 6: Prepare chroot bind mounts
# =============================================================================
prepare_chroot() {
    step 6 "Preparing chroot environment"

    mount --bind /dev     "$MOUNTPOINT/dev"
    mount --bind /dev/pts "$MOUNTPOINT/dev/pts"
    mount --bind /proc    "$MOUNTPOINT/proc"
    mount --bind /sys     "$MOUNTPOINT/sys"
    mount --bind /run     "$MOUNTPOINT/run"
    # Remove the target's resolv.conf (often a symlink into /run on systemd-resolved
    # hosts) before copying — after binding /run both paths resolve to the same
    # physical file, which causes cp to error.
    rm -f "$MOUNTPOINT/etc/resolv.conf"
    cp -L /etc/resolv.conf "$MOUNTPOINT/etc/resolv.conf"

    ok "Chroot bind mounts ready."
}

# Helper: run a command inside the chroot with our env vars
run_in_chroot() {
    chroot "$MOUNTPOINT" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        export PATH=/usr/sbin:/usr/bin:/sbin:/bin
        $1
    "
}

# =============================================================================
# Step 7: Configure system inside chroot
# =============================================================================
chroot_configure_system() {
    step 7 "Configuring system inside chroot"

    # ── APT sources ─────────────────────────────────────────────────────────
    chroot_info "Configuring APT sources for $RELEASE..."

    cat > "$MOUNTPOINT/etc/apt/sources.list.d/ubuntu.sources" << EOF
Types: deb
URIs: $MIRROR
Suites: ${RELEASE} ${RELEASE}-updates ${RELEASE}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
    rm -f "$MOUNTPOINT/etc/apt/sources.list"

    run_in_chroot "apt-get update -qq"
    chroot_ok "APT sources configured."

    # ── Pre-seed debconf ────────────────────────────────────────────────────
    run_in_chroot "echo 'man-db man-db/auto-update boolean false' | debconf-set-selections"

    # ── Install packages ────────────────────────────────────────────────────
    chroot_info "Installing kernel, bootloader, and essential packages..."

    local PACKAGES=(
        linux-generic
        grub-efi-amd64
        grub-efi-amd64-signed
        shim-signed
        f2fs-tools
        systemd-sysv
        sudo
        openssh-server
        systemd-resolved
        nano
        less
        bash-completion
        ubuntu-minimal
    )
    if $ENABLE_SWAP; then
        PACKAGES+=(zram-tools)
    fi

    run_in_chroot "apt-get install -y -qq ${PACKAGES[*]}"
    chroot_ok "Packages installed."

    # ── Locale & timezone ───────────────────────────────────────────────────
    chroot_info "Setting locale and timezone..."
    run_in_chroot "
        echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
        locale-gen
        echo 'LANG=en_US.UTF-8' > /etc/default/locale
        ln -sf /usr/share/zoneinfo/UTC /etc/localtime
        dpkg-reconfigure -f noninteractive tzdata
    "
    chroot_ok "Locale: en_US.UTF-8, Timezone: UTC"

    # ── Hostname ────────────────────────────────────────────────────────────
    chroot_info "Setting hostname to $HOSTNAME_TARGET..."
    echo "$HOSTNAME_TARGET" > "$MOUNTPOINT/etc/hostname"
    cat > "$MOUNTPOINT/etc/hosts" << EOF
127.0.0.1   localhost
127.0.1.1   ${HOSTNAME_TARGET}

::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

    # ── Create user ─────────────────────────────────────────────────────────
    chroot_info "Creating user '$DEFAULT_USER'..."
    run_in_chroot "
        useradd -m -s /bin/bash -G sudo '$DEFAULT_USER'
        echo '${DEFAULT_USER}:${DEFAULT_PASS}' | chpasswd
        chage -d 0 '$DEFAULT_USER'
    "
    chroot_ok "User '$DEFAULT_USER' created (password change forced on first login)."

    # ── fstab ───────────────────────────────────────────────────────────────
    chroot_info "Writing /etc/fstab..."

    local ROOT_UUID EFI_UUID
    ROOT_UUID=$(blkid -s UUID -o value "$PART_ROOT")
    EFI_UUID=$(blkid -s UUID -o value "$PART_EFI")

    cat > "$MOUNTPOINT/etc/fstab" << EOF
# =============================================================================
# USB Flash Drive fstab — F2FS compressed root + zram volatile dirs
# =============================================================================

# Root: F2FS with zstd:6 compression on all files
UUID=${ROOT_UUID}   /           f2fs    compress_algorithm=zstd:6,compress_extension=*,compress_chksum,gc_merge,atgc,lazytime,noatime  0  0

# EFI System Partition
UUID=${EFI_UUID}    /boot/efi   vfat    umask=0077  0  1

# ── Volatile directories — zram (lzo) backed, formatted at boot via udev ──────
/dev/zram0  /tmp        ext4  nosuid,nodev,noatime          0  0
/dev/zram1  /var/tmp    ext4  nosuid,nodev,noatime          0  0
/dev/zram2  /var/log    ext4  nosuid,nodev,noexec,noatime   0  0
/dev/zram3  /var/spool  ext4  nosuid,nodev,noexec,noatime   0  0
/dev/zram4  /var/cache  ext4  nosuid,nodev,noexec,noatime   0  0
EOF
    chroot_ok "fstab written."

    # ── Networking ──────────────────────────────────────────────────────────
    chroot_info "Configuring systemd-networkd..."
    mkdir -p "$MOUNTPOINT/etc/systemd/network"
    cat > "$MOUNTPOINT/etc/systemd/network/80-wired-dhcp.network" << 'EOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes

[DHCPv4]
RouteMetric=100
EOF
    run_in_chroot "
        systemctl enable systemd-networkd
        systemctl enable systemd-resolved
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true
    "
    chroot_ok "Networking: DHCP on all wired interfaces."

    # ── GRUB ────────────────────────────────────────────────────────────────
    chroot_info "Installing GRUB (UEFI, removable)..."
    cat > "$MOUNTPOINT/etc/default/grub" << 'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=3
GRUB_TIMEOUT_STYLE=menu
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX=""
GRUB_TERMINAL=console
GRUB_DISABLE_OS_PROBER=true
EOF
    run_in_chroot "
        grub-install \
            --target=x86_64-efi \
            --efi-directory=/boot/efi \
            --bootloader-id=ubuntu \
            --removable \
            --no-nvram
        update-grub
    "
    chroot_ok "GRUB installed (removable EFI — portable across UEFI machines)."

    # ── initramfs ───────────────────────────────────────────────────────────
    chroot_info "Updating initramfs with F2FS support..."
    run_in_chroot "
        grep -qxF 'f2fs' /etc/initramfs-tools/modules 2>/dev/null || \
            echo 'f2fs' >> /etc/initramfs-tools/modules
        update-initramfs -u -k all
    "
    chroot_ok "initramfs updated."

    ok "System configuration complete."
}

# =============================================================================
# Step 8: Apply write-endurance optimizations
# =============================================================================
apply_write_reduction() {
    step 8 "Applying write-endurance optimizations"

    # ── 8a. Journald → volatile ────────────────────────────────────────────
    chroot_info "journald → volatile (RAM only, 64M cap)..."
    mkdir -p "$MOUNTPOINT/etc/systemd/journald.conf.d"
    cat > "$MOUNTPOINT/etc/systemd/journald.conf.d/volatile.conf" << 'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=64M
RuntimeMaxFileSize=8M
ForwardToSyslog=no
Compress=yes
EOF

    # ── 8b. sysctl tuning ──────────────────────────────────────────────────
    chroot_info "sysctl: writeback=60s, dirty_ratio=40%..."
    cat > "$MOUNTPOINT/etc/sysctl.d/99-usb-flash-endurance.conf" << EOF
# ── Write coalescing ─────────────────────────────────────────────────────────
vm.dirty_writeback_centisecs = 6000
vm.dirty_expire_centisecs = 6000
vm.dirty_ratio = 40
vm.dirty_background_ratio = 5

# ── Swap / cache behavior ────────────────────────────────────────────────────
$($ENABLE_SWAP && echo 'vm.swappiness = 100' || echo '# vm.swappiness left at default (swap disabled)')
vm.vfs_cache_pressure = 50

# ── Misc ─────────────────────────────────────────────────────────────────────
fs.inotify.max_user_watches = 8192
EOF

    # ── 8c. zram swap (conditional) ────────────────────────────────────────
    if $ENABLE_SWAP; then
        chroot_info "zram swap: zstd, 50% of RAM, priority 100..."
        cat > "$MOUNTPOINT/etc/default/zramswap" << 'EOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
        run_in_chroot "systemctl enable zramswap.service 2>/dev/null || true"
    else
        chroot_info "Swap disabled by --no-swap flag."
        # If zram-tools somehow got installed, make sure it stays off
        run_in_chroot "systemctl disable zramswap.service 2>/dev/null || true"
        run_in_chroot "systemctl mask zramswap.service 2>/dev/null || true"
    fi

    # ── 8d. Disable write-heavy timers ─────────────────────────────────────
    chroot_info "Masking write-heavy timers..."
    local MASK_UNITS=(
        apt-daily.timer
        apt-daily-upgrade.timer
        fstrim.timer
        man-db.timer
        e2scrub_all.timer
        e2scrub_reap.service
    )
    for unit in "${MASK_UNITS[@]}"; do
        run_in_chroot "systemctl mask '$unit' 2>/dev/null || true"
    done
    chroot_ok "Masked: ${MASK_UNITS[*]}"

    # ── 8e. Disable core dumps ─────────────────────────────────────────────
    chroot_info "Disabling core dumps..."
    cat > "$MOUNTPOINT/etc/sysctl.d/99-no-coredump.conf" << 'EOF'
kernel.core_pattern=|/bin/false
fs.suid_dumpable = 0
EOF
    mkdir -p "$MOUNTPOINT/etc/security/limits.d"
    cat > "$MOUNTPOINT/etc/security/limits.d/no-coredump.conf" << 'EOF'
*    hard    core    0
*    soft    core    0
EOF
    run_in_chroot "systemctl mask systemd-coredump.socket 2>/dev/null || true"

    # ── 8f. F2FS runtime tuning service ────────────────────────────────────
    chroot_info "Creating f2fs-tune.service (cp_interval=60s, iostat off)..."
    cat > "$MOUNTPOINT/etc/systemd/system/f2fs-tune.service" << 'EOF'
[Unit]
Description=Tune F2FS for USB flash write endurance
After=local-fs.target
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
    DEV=$(findmnt -n -o SOURCE / | sed "s|/dev/||"); \
    F2FS_DIR="/sys/fs/f2fs/$DEV"; \
    if [ -d "$F2FS_DIR" ]; then \
        echo 60 > "$F2FS_DIR/cp_interval" 2>/dev/null || true; \
        echo 0  > "$F2FS_DIR/iostat_enable" 2>/dev/null || true; \
        echo "F2FS tuned: cp_interval=60, iostat=off ($DEV)"; \
    else \
        echo "Warning: F2FS sysfs dir not found for $DEV"; \
    fi'

[Install]
WantedBy=local-fs.target
EOF
    run_in_chroot "systemctl enable f2fs-tune.service 2>/dev/null || true"

    # ── 8g. Slow down tmpfiles-clean ───────────────────────────────────────
    chroot_info "tmpfiles-clean interval → 1h..."
    mkdir -p "$MOUNTPOINT/etc/systemd/system/systemd-tmpfiles-clean.timer.d"
    cat > "$MOUNTPOINT/etc/systemd/system/systemd-tmpfiles-clean.timer.d/endurance.conf" << 'EOF'
[Timer]
OnUnitActiveSec=1h
EOF

    # ── 8h. SSH host keys — pre-generate ───────────────────────────────────
    chroot_info "Pre-generating SSH host keys..."
    run_in_chroot "
        ssh-keygen -A 2>/dev/null || true
        systemctl mask ssh-host-keys-generate.service 2>/dev/null || true
    "

    # ── 8i. Disable rsyslog if present ─────────────────────────────────────
    run_in_chroot "
        if dpkg -s rsyslog &>/dev/null; then
            systemctl disable rsyslog.service 2>/dev/null || true
            systemctl mask rsyslog.service 2>/dev/null || true
        fi
    "

    # ── 8j. Disable all APT periodic tasks ─────────────────────────────────
    chroot_info "APT periodic tasks → all disabled..."
    cat > "$MOUNTPOINT/etc/apt/apt.conf.d/99-no-periodic.conf" << 'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF

    # ── 8k. zram-backed volatile directories ───────────────────────────────
    chroot_info "Setting up zram volatile directories (lzo, no-journal ext4, udev+fstab)..."

    # Load zram at boot with 5 pre-allocated devices (zram0–4).
    # If swap is enabled, zramswap will hot-add zram5 via zramctl --find.
    echo 'zram' > "$MOUNTPOINT/etc/modules-load.d/zram-volatile.conf"
    cat > "$MOUNTPOINT/etc/modprobe.d/zram-volatile.conf" << 'EOF'
options zram num_devices=5
EOF

    # One rule per device: set lzo compression + disksize, then format.
    # RUN+= is synchronous, so the device is ready before systemd mounts fstab.
    cat > "$MOUNTPOINT/etc/udev/rules.d/99-zram-volatile.rules" << 'EOF'
KERNEL=="zram0", SUBSYSTEM=="block", DRIVER=="", ACTION=="add", ATTR{initstate}=="0", ATTR{comp_algorithm}="lzo", ATTR{disksize}="2G",   RUN+="/sbin/mkfs.ext4 -q -O ^has_journal -L $name $env{DEVNAME}"
KERNEL=="zram1", SUBSYSTEM=="block", DRIVER=="", ACTION=="add", ATTR{initstate}=="0", ATTR{comp_algorithm}="lzo", ATTR{disksize}="500M", RUN+="/sbin/mkfs.ext4 -q -O ^has_journal -L $name $env{DEVNAME}"
KERNEL=="zram2", SUBSYSTEM=="block", DRIVER=="", ACTION=="add", ATTR{initstate}=="0", ATTR{comp_algorithm}="lzo", ATTR{disksize}="500M", RUN+="/sbin/mkfs.ext4 -q -O ^has_journal -L $name $env{DEVNAME}"
KERNEL=="zram3", SUBSYSTEM=="block", DRIVER=="", ACTION=="add", ATTR{initstate}=="0", ATTR{comp_algorithm}="lzo", ATTR{disksize}="256M", RUN+="/sbin/mkfs.ext4 -q -O ^has_journal -L $name $env{DEVNAME}"
KERNEL=="zram4", SUBSYSTEM=="block", DRIVER=="", ACTION=="add", ATTR{initstate}=="0", ATTR{comp_algorithm}="lzo", ATTR{disksize}="1G",   RUN+="/sbin/mkfs.ext4 -q -O ^has_journal -L $name $env{DEVNAME}"
EOF
    chroot_ok "zram volatile directories configured (udev + fstab)."

    ok "All write-endurance optimizations applied."
}

# =============================================================================
# Step 9: Install verification script onto target
# =============================================================================
install_verify_script() {
    step 9 "Installing post-boot verification script"

    # We need to know the swap setting inside the script
    local SWAP_CHECK_BLOCK=""
    if $ENABLE_SWAP; then
        SWAP_CHECK_BLOCK='
echo ""
echo "Swap:"
if swapon --show --noheadings 2>/dev/null | grep -q zram; then
    SIZE=$(swapon --show --noheadings | awk "/zram/{print \$3}")
    check "zram swap active ($SIZE)" "pass"
else
    check "zram swap active" "fail"
fi

DISK_SWAP=$(swapon --show --noheadings 2>/dev/null | grep -v zram || true)
if [[ -z "$DISK_SWAP" ]]; then
    check "No disk-based swap" "pass"
else
    check "No disk-based swap (FOUND: $DISK_SWAP)" "fail"
fi'
    else
        SWAP_CHECK_BLOCK='
echo ""
echo "Swap:"
if swapon --show --noheadings 2>/dev/null | grep -q .; then
    check "Swap disabled (but swap IS active — unexpected)" "fail"
else
    check "Swap disabled (none active)" "pass"
fi'
    fi

    cat > "$MOUNTPOINT/usr/local/sbin/verify-usb-setup.sh" << VERIFYEOF
#!/usr/bin/env bash
# =============================================================================
# verify-usb-setup.sh — Check that all write-endurance optimizations are active
# Run: sudo /usr/local/sbin/verify-usb-setup.sh
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0

check() {
    local desc="\$1" result="\$2"
    if [[ "\$result" == "pass" ]]; then
        echo -e "  \${GREEN}✓\${NC} \$desc"; ((PASS++))
    elif [[ "\$result" == "warn" ]]; then
        echo -e "  \${YELLOW}!\${NC} \$desc"; ((WARN++))
    else
        echo -e "  \${RED}✗\${NC} \$desc"; ((FAIL++))
    fi
}

echo ""
echo "═══════════════════════════════════════════════════"
echo " USB Flash Drive — Write Endurance Verification"
echo "═══════════════════════════════════════════════════"

# ── Filesystem ─────────────────────────────────────────────────────────────
echo ""
echo "Filesystem:"
ROOT_OPTS=\$(findmnt -n -o OPTIONS /)

[[ "\$ROOT_OPTS" == *f2fs* ]]                         && r="pass" || r="fail"; check "Root is F2FS" "\$r"
[[ "\$ROOT_OPTS" == *compress_algorithm=zstd* ]]      && r="pass" || r="fail"; check "zstd compression active" "\$r"
[[ "\$ROOT_OPTS" == *noatime* ]]                      && r="pass" || r="fail"; check "noatime set" "\$r"
[[ "\$ROOT_OPTS" == *lazytime* ]]                     && r="pass" || r="fail"; check "lazytime set" "\$r"

# ── Volatile directories (zram-backed) ─────────────────────────────────────
echo ""
echo "Volatile directories (zram):"
for dir in /tmp /var/log /var/spool /var/cache /var/tmp; do
    src=\$(findmnt -n -o SOURCE "\$dir" 2>/dev/null || echo "none")
    [[ "\$src" == /dev/zram* ]] && check "\$dir → zram" "pass" \
                                || check "\$dir → zram (got: \$src)" "fail"
done

# ── Swap ───────────────────────────────────────────────────────────────────
${SWAP_CHECK_BLOCK}

# ── Journald ──────────────────────────────────────────────────────────────
echo ""
echo "Journald:"
if [[ -d /run/log/journal ]] && [[ ! -d /var/log/journal ]]; then
    check "Storage is volatile (RAM)" "pass"
elif [[ -d /var/log/journal ]]; then
    check "Storage is volatile (WARNING: /var/log/journal exists)" "warn"
else
    check "Storage is volatile" "pass"
fi

# ── Kernel tuning ─────────────────────────────────────────────────────────
echo ""
echo "Kernel tuning:"
WB=\$(cat /proc/sys/vm/dirty_writeback_centisecs 2>/dev/null || echo 0)
[[ "\$WB" -ge 6000 ]] && check "dirty_writeback ≥ 60s (\${WB}cs)" "pass" \
                       || check "dirty_writeback ≥ 60s (got: \${WB}cs)" "fail"

DR=\$(cat /proc/sys/vm/dirty_ratio 2>/dev/null || echo 0)
[[ "\$DR" -ge 30 ]] && check "dirty_ratio ≥ 30% (\${DR}%)" "pass" \
                     || check "dirty_ratio ≥ 30% (got: \${DR}%)" "fail"

SW=\$(cat /proc/sys/vm/swappiness 2>/dev/null || echo 0)
[[ "\$SW" -ge 100 ]] && check "swappiness = 100 (\$SW)" "pass" \
                      || check "swappiness ≥ 100 (got: \$SW)" "warn"

# ── F2FS tuning ──────────────────────────────────────────────────────────
echo ""
echo "F2FS tuning:"
DEV=\$(findmnt -n -o SOURCE / | sed 's|/dev/||')
F2FS_DIR="/sys/fs/f2fs/\$DEV"
if [[ -d "\$F2FS_DIR" ]]; then
    CP=\$(cat "\$F2FS_DIR/cp_interval" 2>/dev/null || echo "0")
    [[ "\$CP" -ge 60 ]] && check "cp_interval ≥ 60s (\${CP}s)" "pass" \
                        || check "cp_interval ≥ 60s (got: \${CP}s)" "warn"
else
    check "F2FS sysfs directory found" "fail"
fi

# ── Masked services ──────────────────────────────────────────────────────
echo ""
echo "Masked services:"
for svc in apt-daily.timer apt-daily-upgrade.timer fstrim.timer systemd-coredump.socket; do
    STATE=\$(systemctl is-enabled "\$svc" 2>/dev/null || echo "not-found")
    if [[ "\$STATE" == "masked" ]]; then
        check "\$svc" "pass"
    elif [[ "\$STATE" == "not-found" ]]; then
        check "\$svc (not installed — OK)" "pass"
    else
        check "\$svc (state: \$STATE)" "fail"
    fi
done

# ── Summary ──────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
echo -e " Results: \${GREEN}\$PASS passed\${NC}, \${YELLOW}\$WARN warnings\${NC}, \${RED}\$FAIL failed\${NC}"
echo "═══════════════════════════════════════════════════"
echo ""
[[ \$FAIL -eq 0 ]] && exit 0 || exit 1
VERIFYEOF

    chmod +x "$MOUNTPOINT/usr/local/sbin/verify-usb-setup.sh"
    ok "Verification script installed at /usr/local/sbin/verify-usb-setup.sh"
}

# =============================================================================
# Step 10: Final cleanup
# =============================================================================
final_cleanup() {
    step 10 "Final cleanup and unmount"

    run_in_chroot "
        apt-get clean
        rm -rf /var/lib/apt/lists/*
        rm -rf /var/cache/apt/archives/*.deb
    "

    cleanup_mounts
    sync

    ok "Installation complete!"
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  USB drive is ready!                                          ║${NC}"
    echo -e "${GREEN}║                                                               ║${NC}"
    echo -e "${GREEN}$(printf '║%-63s║' "  Target  : $TARGET")${NC}"
    echo -e "${GREEN}$(printf '║%-63s║' "  Login   : $DEFAULT_USER / $DEFAULT_PASS")${NC}"
    echo -e "${GREEN}$(printf '║%-63s║' "  Swap    : $($ENABLE_SWAP && echo 'zram (zstd)' || echo 'DISABLED')")${NC}"
    echo -e "${GREEN}║                                                               ║${NC}"
    echo -e "${GREEN}║  ⚠  CHANGE YOUR PASSWORD on first login!                     ║${NC}"
    echo -e "${GREEN}║                                                               ║${NC}"
    echo -e "${GREEN}║  After boot, verify with:                                     ║${NC}"
    echo -e "${GREEN}║    sudo /usr/local/sbin/verify-usb-setup.sh                   ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# =============================================================================
# Main
# =============================================================================
main() {
    parse_args "$@"
    trap 'on_error $LINENO' ERR

    preflight
    partition_drive
    create_filesystems
    mount_target
    run_debootstrap
    prepare_chroot
    chroot_configure_system
    apply_write_reduction
    install_verify_script
    final_cleanup
}

main "$@"
