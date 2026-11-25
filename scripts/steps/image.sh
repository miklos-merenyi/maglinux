#!/bin/bash
# Assemble the SD card image: one bootable FAT32 partition holding syslinux and the
# kernel + initrd (boot/), rootfs.btrfs and the rescue system (rescue/).
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

# FAT32 with FAT_CLUSTER_SIZE clusters and FAT tables sized for FAT_MAX_SIZE, so the initramfs
# can grow it on a larger card by changing only the size fields (mount-btrfs-loop).
# mkfs.fat is given the larger size (it warns about the mismatch), then the
# filesystem size is set back to the partition: total sectors in the boot sector
# and its backup (sector 6), free cluster count "unknown" in FSInfo and its
# backup (sector 7), so it is recounted on mount.
le32() {
    printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(($1 & 255)) $(($1 >> 8 & 255)) \
        $(($1 >> 16 & 255)) $(($1 >> 24 & 255)))"
}
PART_SECTORS=$(sudo blockdev --getsz "$PART_DEV")
FAT_MAX_KIB=$(( $(numfmt --from=iec "$FAT_MAX_SIZE") / 1024 ))
FAT_CLUSTER_SECTORS=$(( $(numfmt --from=iec "$FAT_CLUSTER_SIZE") / 512 ))
sudo mkfs.vfat -F 32 -s "$FAT_CLUSTER_SECTORS" -n BOOT "$PART_DEV" "$FAT_MAX_KIB" 2>&1 | grep -v 'block count mismatch'
for s in 0 6; do
    le32 "$PART_SECTORS" | sudo dd of="$PART_DEV" bs=1 seek=$((s * 512 + 32)) conv=notrunc status=none
done
for s in 1 7; do
    le32 4294967295 | sudo dd of="$PART_DEV" bs=1 seek=$((s * 512 + 488)) conv=notrunc status=none
done
sudo fsck.fat -n "$PART_DEV" >/dev/null

mkdir -p "$MNT"
sudo mount "$PART_DEV" "$MNT"
# maglin's data and dres directories (/opt/maglin/data and /opt/maglin/dres link here)
sudo mkdir "$MNT/data" "$MNT/dres"
# Files for the card's user-editable area (config/wireguard/, ...)
sudo cp -r "$REPO/sdcard/." "$MNT/"

# Kernel, initrd, Btrfs image
sudo mkdir -p "$MNT/boot/syslinux"
sudo cp "$ROOTFS_DIR/boot/vmlinuz-"* "$MNT/boot/vmlinuz"
sudo cp "$ROOTFS_DIR/boot/initrd.img-"* "$MNT/boot/initrd.img"
sudo cp "$BTRFS_IMG" "$MNT/"

# Rescue system and boot menu. Syslinux reads syslinux.cfg and loads the menu modules
# from its install directory, boot/syslinux/ (the modules must match the installed
# syslinux version).
sudo mkdir -p "$MNT/rescue"
sudo cp "$RESCUE_OUT/initramfs.gz" "$RESCUE_OUT/rescue.sqfs" "$MNT/rescue/"
sudo cp /usr/lib/syslinux/modules/bios/menu.c32 /usr/lib/syslinux/modules/bios/libutil.c32 \
    "$MNT/boot/syslinux/"

sudo tee "$MNT/boot/syslinux/syslinux.cfg" > /dev/null <<EOF
UI menu.c32
PROMPT 0
TIMEOUT 50
MENU TITLE $HOSTNAME_NEW boot menu
DEFAULT linux

LABEL linux
    MENU LABEL $HOSTNAME_NEW (Debian 12)
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img root=/dev/loop0 rootfstype=btrfs rootflags=compress=zstd:3 rw

LABEL rescue
    MENU LABEL Rescue system (root autologin, SD card writable)
    KERNEL /boot/vmlinuz
    APPEND initrd=/rescue/initramfs.gz console=ttyS0,115200 console=tty0
EOF

safe_umount "$MNT"
# ldlinux.sys and ldlinux.c32 into boot/syslinux/ (the directory must exist)
sudo syslinux -i -d /boot/syslinux "$PART_DEV"
# syslinux writes its name and boot code only into the primary boot sector; copy it
# to the backup (sector 6) so fsck.fat does not report differences
sudo dd if="$PART_DEV" of="$PART_DEV" bs=512 count=1 seek=6 conv=notrunc status=none
sudo fsck.fat -n "$PART_DEV" >/dev/null
detach_loops "$TMP"
# Write Syslinux MBR
dd bs=440 count=1 conv=notrunc status=none if=/usr/lib/syslinux/mbr/mbr.bin of="$TMP"

mv "$TMP" "$SD_IMG"
echo "Build complete: $SD_IMG"
