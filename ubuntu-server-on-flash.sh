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
# Main
# =============================================================================
main() {
    parse_args "$@"
    trap 'on_error $LINENO' ERR

    preflight
    partition_drive
    create_filesystems
}

main "$@"
