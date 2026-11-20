#!/bin/bash
set -eEuo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Please run as root: sudo $0" >&2
    exit 1
fi

IMG_NAME="sdcard-8g.img"
BTRFS_IMG="rootfs.btrfs"

# System identity / credentials
HOSTNAME_NEW="maglinux"
USER_NAME="maguser"
USER_PASS="maguser"
VNC_PASS="maguser"
ROOT_PASS="magroot"
WORK_DIR="./build"
mkdir -p "$WORK_DIR"
WORK_DIR="$(realpath "$WORK_DIR")"

# Unmount a mountpoint (and anything mounted below it); fall back to lazy umount if busy
safe_umount() {
    local m="$1"
    mountpoint -q "$m" 2>/dev/null || return 0
    sync
    umount -R "$m" 2>/dev/null || { sleep 1; umount -R "$m" 2>/dev/null; } || {
        echo "WARN: $m busy, using lazy unmount" >&2
        umount -R -l "$m" || true
    }
}

# Tear down everything this (or a previous, failed) run may have left behind
cleanup() {
    set +e
    # Anything mounted inside our work dir (mnt_fat, mnt_btrfs, rootfs/proc, ...)
    grep -F " $WORK_DIR/" /proc/mounts | awk '{print $2}' | sort -r | while read -r m; do
        safe_umount "$m"
    done
    # Loop devices backed by our images (also catches "(deleted)" image files)
    for f in "$IMG_NAME" "$BTRFS_IMG"; do
        losetup -a | grep -F "$WORK_DIR/$f" | cut -d: -f1 | while read -r dev; do
            kpartx -d "$dev" 2>/dev/null
            for p in /dev/mapper/"$(basename "$dev")"p*; do
                [[ -e $p ]] && dmsetup remove "$p" 2>/dev/null
            done
            losetup -d "$dev" 2>/dev/null
        done
    done
    # Stale device-mapper partitions whose loop device is already gone
    for p in /dev/mapper/loop*p*; do
        [[ -e $p ]] || continue
        dev="/dev/$(basename "$p" | sed 's/p[0-9]*$//')"
        losetup "$dev" >/dev/null 2>&1 || dmsetup remove "$p" 2>/dev/null
    done
    udevadm settle 2>/dev/null
    return 0
}

on_exit() {
    local rc=$?
    trap - EXIT INT TERM ERR
    cleanup
    if [[ $rc -ne 0 ]]; then
        echo "Build FAILED (exit $rc) - mounts and loop devices have been cleaned up." >&2
    fi
    exit $rc
}
on_error() {
    echo "ERROR: command failed at line $1: $2" >&2
}

cleanup
trap on_exit EXIT
trap 'exit 130' INT TERM
trap 'on_error $LINENO "$BASH_COMMAND"' ERR

sudo rm -rf "$WORK_DIR/rootfs" "$WORK_DIR/$BTRFS_IMG" "$WORK_DIR/$IMG_NAME"

# 1. Bootstrap Debian 12 i386
mmdebstrap --arch=i386 --variant=minbase \
    --aptopt='Apt::Install-Recommends "false";' \
    --aptopt='Acquire::http::Proxy "http://127.0.0.1:3142";' \
    --include="linux-image-686-pae,systemd-sysv,btrfs-progs,initramfs-tools,syslinux,dosfstools,udev,kmod,ifupdown,isc-dhcp-client,openssh-server,zstd,xfce4,xfce4-terminal,dbus-x11,tigervnc-standalone-server,tigervnc-tools,network-manager,network-manager-gnome,polkitd,logrotate,sudo" \
    bookworm "$WORK_DIR/rootfs" http://deb.debian.org/debian

# 2. Apply Git-tracked overlays & configure fstab
cp -r "$(dirname "$(realpath "$0")")/../overlay/." "$WORK_DIR/rootfs/"
# initramfs-tools silently ignores hooks/scripts that are not executable
find "$WORK_DIR/rootfs/etc/initramfs-tools/hooks" "$WORK_DIR/rootfs/etc/initramfs-tools/scripts" \
    -type f ! -name ORDER -exec chmod 755 {} +
echo "/dev/loop0 / btrfs defaults,compress=zstd:3,noatime 0 1" > "$WORK_DIR/rootfs/etc/fstab"
echo "$HOSTNAME_NEW" > "$WORK_DIR/rootfs/etc/hostname"
cat > "$WORK_DIR/rootfs/etc/hosts" <<HOSTS
127.0.0.1	localhost
127.0.1.1	$HOSTNAME_NEW
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
HOSTS

# Root password and default user
chroot "$WORK_DIR/rootfs" useradd -m -s /bin/bash "$USER_NAME"
for g in sudo audio video plugdev netdev users; do
    if chroot "$WORK_DIR/rootfs" getent group "$g" >/dev/null; then
        chroot "$WORK_DIR/rootfs" usermod -aG "$g" "$USER_NAME"
    fi
done
printf '%s\n' "root:$ROOT_PASS" "$USER_NAME:$USER_PASS" | chroot "$WORK_DIR/rootfs" chpasswd

# VNC password for the default user (~/.vnc/passwd, used by vncserver)
chroot "$WORK_DIR/rootfs" install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "/home/$USER_NAME/.vnc"
printf '%s\n' "$VNC_PASS" | chroot "$WORK_DIR/rootfs" vncpasswd -f > "$WORK_DIR/rootfs/home/$USER_NAME/.vnc/passwd"
chroot "$WORK_DIR/rootfs" chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.vnc/passwd"
chmod 600 "$WORK_DIR/rootfs/home/$USER_NAME/.vnc/passwd"

# Autostart VNC server on display :1 (port 5901) for the default user, reachable from the network
echo ":1=$USER_NAME" > "$WORK_DIR/rootfs/etc/tigervnc/vncserver.users"
cat >> "$WORK_DIR/rootfs/etc/tigervnc/vncserver-config-defaults" <<'VNCCFG'

# maglinux: accept connections from the network, default desktop size
$localhost = "no";
$geometry = "1280x800";
1;
VNCCFG
chroot "$WORK_DIR/rootfs" systemctl enable 'tigervncserver@:1.service'

chroot "$WORK_DIR/rootfs" update-initramfs -u

# 3. Create compressed Btrfs image (6GB max capacity, sparse file)
truncate -s 3800M "$WORK_DIR/$BTRFS_IMG"
mkfs.btrfs -f -L DEBIAN_ROOT "$WORK_DIR/$BTRFS_IMG"

mkdir -p "$WORK_DIR/mnt_btrfs"
sudo mount -o loop,compress=zstd:3 "$WORK_DIR/$BTRFS_IMG" "$WORK_DIR/mnt_btrfs"
sudo cp -a "$WORK_DIR/rootfs/." "$WORK_DIR/mnt_btrfs/"
safe_umount "$WORK_DIR/mnt_btrfs"

# 4. Build the 8GB vfat SD card image
truncate -s 7500M "$WORK_DIR/$IMG_NAME" # Slightly under 8GB to fit any 8GB SD card
sudo chmod 666 "$WORK_DIR/$IMG_NAME"
parted -s "$WORK_DIR/$IMG_NAME" mklabel msdos
parted -s "$WORK_DIR/$IMG_NAME" mkpart primary fat32 1MiB 100%
parted -s "$WORK_DIR/$IMG_NAME" set 1 boot on

# Attach image on a fresh loop device with partition scanning
LOOP_DEV=$(losetup -f -P --show "$WORK_DIR/$IMG_NAME")
PART_DEV="${LOOP_DEV}p1"
udevadm settle
for _ in 1 2 3 4 5; do [[ -b $PART_DEV ]] && break; sleep 1; done
[[ -b $PART_DEV ]] || { echo "Partition $PART_DEV did not appear" >&2; exit 1; }
if findmnt -S "$PART_DEV" >/dev/null; then
    echo "$PART_DEV is unexpectedly mounted, aborting" >&2; exit 1
fi

sudo mkfs.vfat -F 32 -n BOOT "$PART_DEV"
sudo syslinux -i "$PART_DEV"

mkdir -p "$WORK_DIR/mnt_fat"
sudo mount "$PART_DEV" "$WORK_DIR/mnt_fat"

# Copy kernel, initrd, Btrfs image, and Syslinux config
sudo cp "$WORK_DIR/rootfs/boot/vmlinuz-"* "$WORK_DIR/mnt_fat/vmlinuz"
sudo cp "$WORK_DIR/rootfs/boot/initrd.img-"* "$WORK_DIR/mnt_fat/initrd.img"
sudo cp "$WORK_DIR/$BTRFS_IMG" "$WORK_DIR/mnt_fat/"

sudo tee "$WORK_DIR/mnt_fat/syslinux.cfg" > /dev/null <<EOF
DEFAULT linux
LABEL linux
    KERNEL /vmlinuz
    APPEND initrd=/initrd.img root=/dev/loop0 rootfstype=btrfs rootflags=compress=zstd:3 rw
EOF

safe_umount "$WORK_DIR/mnt_fat"
losetup -d "$LOOP_DEV"
# Write Syslinux MBR
sudo dd bs=440 count=1 conv=notrunc if=/usr/lib/syslinux/mbr/mbr.bin of="$WORK_DIR/$IMG_NAME"

echo "Build complete: $WORK_DIR/$IMG_NAME"
