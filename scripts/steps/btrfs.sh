#!/bin/bash
# Pack build/rootfs into the compressed Btrfs image build/rootfs.btrfs (sparse file).
. "$(dirname "$(realpath "$0")")/../lib.sh"
. "$CONFIG/settings.sh"

MNT="$B/mnt_btrfs"
TMP="$BTRFS_IMG.tmp"

cleanup_btrfs() {
    safe_umount "$MNT"
    detach_loops "$TMP"
    rm -f "$TMP"
}
cleanup_btrfs   # leftovers of an interrupted run
on_cleanup cleanup_btrfs

truncate -s "$BTRFS_SIZE" "$TMP"
mkfs.btrfs -q -f -L DEBIAN_ROOT "$TMP"

mkdir -p "$MNT"
sudo mount -o loop,compress=zstd:3 "$TMP" "$MNT"
sudo cp -a "$ROOTFS_DIR/." "$MNT/"
safe_umount "$MNT"

mv "$TMP" "$BTRFS_IMG"
