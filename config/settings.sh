# shellcheck shell=bash
# Identity, credentials and sizes of the main system, sourced by the build steps.
# Changing this rebuilds rootfs, rootfs.btrfs and the SD card image, not the bootstrap.

HOSTNAME_NEW="maglinux"
USER_NAME="maguser"
USER_PASS="maguser"
VNC_PASS="maguser"
ROOT_PASS="magroot"

BTRFS_SIZE="2000M"   # rootfs.btrfs (sparse) on the FAT partition
IMG_SIZE="4000M"     # SD card image
# Largest size the FAT partition can grow to on the first boot (on a larger card the
# rest stays unused). Its FAT tables are sized for this at build time, which costs
# 2 MiB per GiB of FAT_MAX_SIZE with 4K clusters (128 MiB for 64G) on every card.
FAT_MAX_SIZE="64G"
# FAT cluster size: the smallest space a file takes. Larger clusters make the FAT
# tables smaller (16K: 32 MiB for 64G).
FAT_CLUSTER_SIZE="4K"
