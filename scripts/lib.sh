# shellcheck shell=bash
# Common setup for the build steps (scripts/steps/*.sh), sourced first by each.
# The steps run as a normal user; privileged commands use sudo.

set -eEuo pipefail

# The host's locale (e.g. en_IE.UTF-8) does not exist inside the chroots; use C
# so perl/apt/dpkg there don't print "Setting locale failed" warnings.
# sudo passes LANG/LANGUAGE/LC_* through, so this also reaches the chroots.
export LC_ALL=C LANG=C LANGUAGE=
echo $PATH | grep -q /sbin || export PATH=$PATH:/sbin:/usr/sbin

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$REPO/config"

# Build tree layout (the Makefile uses the same paths)
B="$REPO/build"
BASE_DIR="$B/base"                   # mmdebstrap output, main system (root-owned)
ROOTFS_DIR="$B/rootfs"               # configured copy of BASE_DIR
RESCUE_BASE_DIR="$B/rescue-base"     # mmdebstrap output, rescue system
RESCUE_ROOT_DIR="$B/rescue-root"     # configured copy of RESCUE_BASE_DIR
RESCUE_OUT="$B/rescue"               # initramfs.gz, rescue.sqfs
BTRFS_IMG="$B/rootfs.btrfs"
SD_IMG="$B/sdcard-8g.img"

# apt-cacher-ng on the build host; set APT_PROXY= (empty) to download directly
APT_PROXY="${APT_PROXY-http://127.0.0.1:3142}"

mkdir -p "$B"

# Lines of a config list file, without comments and blank lines
read_list() {
    grep -Ev '^[[:space:]]*(#|$)' "$1" | sed 's/[[:space:]]*$//'
}

# Unmount a mountpoint (and anything mounted below it); fall back to lazy umount if busy
safe_umount() {
    local m="$1"
    mountpoint -q "$m" 2>/dev/null || return 0
    sync
    sudo umount -R "$m" 2>/dev/null || { sleep 1; sudo umount -R "$m" 2>/dev/null; } || {
        echo "WARN: $m busy, using lazy unmount" >&2
        sudo umount -R -l "$m" || true
    }
}

# Detach the loop devices backed by an image file (also "(deleted)" ones) and their
# device-mapper partitions
detach_loops() {
    local img="$1" dev p
    sudo losetup -a | { grep -F "($img" || true; } | cut -d: -f1 | while read -r dev; do
        sudo kpartx -d "$dev" 2>/dev/null || true
        for p in /dev/mapper/"$(basename "$dev")"p*; do
            [[ -e $p ]] && sudo dmsetup remove "$p" 2>/dev/null
        done
        sudo losetup -d "$dev" 2>/dev/null || true
    done
    sudo udevadm settle 2>/dev/null || true
}

# Functions run on exit (success or failure), in registration order
CLEANUP_HOOKS=()
on_cleanup() { CLEANUP_HOOKS+=("$1"); }

STEP_NAME="$(basename "$0" .sh)"
SUDO_KEEPALIVE_PID=

on_exit() {
    local rc=$? h
    trap - EXIT INT TERM ERR
    set +e
    for h in "${CLEANUP_HOOKS[@]}"; do "$h"; done
    [[ -n $SUDO_KEEPALIVE_PID ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    if [[ $rc -ne 0 ]]; then
        echo "Step '$STEP_NAME' FAILED (exit $rc) - its mounts and loop devices have been cleaned up." >&2
    fi
    exit $rc
}
trap on_exit EXIT
trap 'exit 130' INT TERM
trap 'echo "ERROR: $STEP_NAME line $LINENO: $BASH_COMMAND" >&2' ERR

# Ask for the sudo password once and keep the timestamp fresh during long steps
# (the loop also ends when this step's shell is gone)
sudo -v
( while sleep 50 && kill -0 $$ 2>/dev/null; do sudo -n -v 2>/dev/null || exit; done ) >/dev/null 2>&1 &
SUDO_KEEPALIVE_PID=$!

echo "=== $STEP_NAME"
