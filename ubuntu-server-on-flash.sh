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
    local DEPS=(debootstrap f2fs-tools dosfstools gdisk)
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
# USB Flash Drive fstab — F2FS compressed root + tmpfs volatile dirs
# =============================================================================

# Root: F2FS with zstd:6 compression on all files
UUID=${ROOT_UUID}   /           f2fs    compress_algorithm=zstd:6,compress_extension=*,compress_chksum,gc_merge,atgc,lazytime,noatime  0  0

# EFI System Partition
UUID=${EFI_UUID}    /boot/efi   vfat    umask=0077  0  1

# ── Volatile directories on tmpfs (never touch flash) ────────────────────────
tmpfs   /tmp          tmpfs   nosuid,nodev,size=50%                 0  0
tmpfs   /var/tmp      tmpfs   nosuid,nodev,size=200M                0  0
tmpfs   /var/log      tmpfs   nosuid,nodev,noexec,size=200M         0  0
tmpfs   /var/spool    tmpfs   nosuid,nodev,noexec,size=100M         0  0
tmpfs   /var/cache    tmpfs   nosuid,nodev,noexec,size=500M         0  0
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
}

main "$@"
