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
