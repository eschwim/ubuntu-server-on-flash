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
# Main
# =============================================================================
main() {
    parse_args "$@"
    trap 'on_error $LINENO' ERR
}

main "$@"
