#!/bin/bash
# Assemble the SD card image: one bootable FAT32 partition holding syslinux, the
# kernel + initrd, rootfs.btrfs and the rescue system.
. "$(dirname "$(realpath "$0")")/../lib.sh"
. "$CONFIG/settings.sh"

MNT="$B/mnt_fat"
TMP="$SD_IMG.tmp"

cleanup_image() {
    safe_umount "$MNT"
    detach_loops "$TMP"
    rm -f "$TMP"
}
cleanup_image   # leftovers of an interrupted run
on_cleanup cleanup_image

truncate -s "$IMG_SIZE" "$TMP"
parted -s "$TMP" mklabel msdos
parted -s "$TMP" mkpart primary fat32 1MiB 100%
parted -s "$TMP" set 1 boot on

# Attach image on a fresh loop device with partition scanning
LOOP_DEV=$(sudo losetup -f -P --show "$TMP")
PART_DEV="${LOOP_DEV}p1"
sudo udevadm settle
for _ in 1 2 3 4 5; do [[ -b $PART_DEV ]] && break; sleep 1; done
[[ -b $PART_DEV ]] || { echo "Partition $PART_DEV did not appear" >&2; exit 1; }
if findmnt -S "$PART_DEV" >/dev/null; then
    echo "$PART_DEV is unexpectedly mounted, aborting" >&2; exit 1
fi

sudo mkfs.vfat -F 32 -n BOOT "$PART_DEV"
sudo syslinux -i "$PART_DEV"

mkdir -p "$MNT"
sudo mount "$PART_DEV" "$MNT"
sudo mkdir "$MNT/data"

# Kernel, initrd, Btrfs image
sudo cp "$ROOTFS_DIR/boot/vmlinuz-"* "$MNT/vmlinuz"
sudo cp "$ROOTFS_DIR/boot/initrd.img-"* "$MNT/initrd.img"
sudo cp "$BTRFS_IMG" "$MNT/"

# Rescue system and boot menu (menu modules must match the installed syslinux version)
sudo mkdir -p "$MNT/rescue"
sudo cp "$RESCUE_OUT/initramfs.gz" "$RESCUE_OUT/rescue.sqfs" "$MNT/rescue/"
sudo cp /usr/lib/syslinux/modules/bios/menu.c32 /usr/lib/syslinux/modules/bios/libutil.c32 "$MNT/"

sudo tee "$MNT/syslinux.cfg" > /dev/null <<EOF
UI menu.c32
PROMPT 0
TIMEOUT 50
MENU TITLE $HOSTNAME_NEW boot menu
DEFAULT linux

LABEL linux
    MENU LABEL $HOSTNAME_NEW (Debian 12)
    KERNEL /vmlinuz
    APPEND initrd=/initrd.img root=/dev/loop0 rootfstype=btrfs rootflags=compress=zstd:3 rw

LABEL rescue
    MENU LABEL Rescue system (read-only, root autologin)
    KERNEL /vmlinuz
    APPEND initrd=/rescue/initramfs.gz console=ttyS0,115200 console=tty0
EOF

safe_umount "$MNT"
detach_loops "$TMP"
# Write Syslinux MBR
dd bs=440 count=1 conv=notrunc status=none if=/usr/lib/syslinux/mbr/mbr.bin of="$TMP"

mv "$TMP" "$SD_IMG"
echo "Build complete: $SD_IMG"
