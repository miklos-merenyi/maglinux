#!/bin/bash
set -e

IMG_NAME="sdcard-8g.img"
BTRFS_IMG="rootfs.btrfs"
WORK_DIR="./build"
mkdir -p "$WORK_DIR"
sudo rm -rf "$WORK_DIR/rootfs" "$WORK_DIR/$BTRFS_IMG" "$WORK_DIR/$IMG_NAME"
mkdir -p "$WORK_DIR"

# 1. Bootstrap Debian 12 i386
mmdebstrap --arch=i386 --variant=minbase \
    --aptopt='Apt::Install-Recommends "false";' \
    --aptopt='Acquire::http::Proxy "http://127.0.0.1:3142";' \
    --include="linux-image-686-pae,systemd-sysv,btrfs-progs,initramfs-tools,syslinux,dosfstools,udev,kmod,ifupdown,isc-dhcp-client,openssh-server,zstd,xfce4,xfce4-terminal,dbus-x11,tigervnc-standalone-server" \
    bookworm "$WORK_DIR/rootfs" http://deb.debian.org/debian

# 2. Apply Git-tracked overlays & configure fstab
cp -r overlay/* "$WORK_DIR/rootfs/"
echo "/dev/loop0 / btrfs defaults,compress=zstd:3,noatime 0 1" > "$WORK_DIR/rootfs/etc/fstab"
echo "debian-i386" > "$WORK_DIR/rootfs/etc/hostname"

# Set root password to 'root' for testing
chroot "$WORK_DIR/rootfs" bash -c "echo 'root:root' | chpasswd"
chroot "$WORK_DIR/rootfs" update-initramfs -u

# 3. Create compressed Btrfs image (6GB max capacity, sparse file)
truncate -s 3800M "$WORK_DIR/$BTRFS_IMG"
mkfs.btrfs -f -L DEBIAN_ROOT "$WORK_DIR/$BTRFS_IMG"

mkdir -p "$WORK_DIR/mnt_btrfs"
sudo mount -o loop,compress=zstd:3 "$WORK_DIR/$BTRFS_IMG" "$WORK_DIR/mnt_btrfs"
sudo cp -a "$WORK_DIR/rootfs/." "$WORK_DIR/mnt_btrfs/"
sudo umount "$WORK_DIR/mnt_btrfs"

# 4. Build the 8GB vfat SD card image
truncate -s 7500M "$WORK_DIR/$IMG_NAME" # Slightly under 8GB to fit any 8GB SD card
parted -s "$WORK_DIR/$IMG_NAME" mklabel msdos
parted -s "$WORK_DIR/$IMG_NAME" mkpart primary fat32 1MiB 100%
parted -s "$WORK_DIR/$IMG_NAME" set 1 boot on

# Attach partition via kpartx
LOOP_DEV=$(sudo kpartx -av "$WORK_DIR/$IMG_NAME" | awk '{print $3}' | head -n1)
PART_DEV="/dev/mapper/$LOOP_DEV"

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

sudo umount "$WORK_DIR/mnt_fat"
sudo kpartx -d "$WORK_DIR/$IMG_NAME"
# Write Syslinux MBR
sudo dd bs=440 count=1 conv=notrunc if=/usr/lib/syslinux/mbr/mbr.bin of="$WORK_DIR/$IMG_NAME"

echo "Build complete: $WORK_DIR/$IMG_NAME"
