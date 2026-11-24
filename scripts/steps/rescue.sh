#!/bin/bash
# Build the Debian 12 (i386) rescue system from build/rescue-base.
#
# The rescue system boots the main system's kernel (/boot/vmlinuz on the FAT partition),
# so its kernel modules are copied from the main bootstrap (build/base).
#
# Produces in build/rescue/:
#   initramfs.gz    busybox initramfs (rescue/init) that mounts rescue.sqfs
#   rescue.sqfs     read-only Debian root filesystem (systemd, sshd)
. "$(dirname "$(realpath "$0")")/../lib.sh"
. "$CONFIG/rescue-settings.sh"

# Modules the initramfs needs to find and mount the boot medium
RESCUE_INITRAMFS_MODULES="kernel/drivers/ata/ kernel/drivers/scsi/ kernel/drivers/usb/host/ \
kernel/drivers/usb/storage/ kernel/drivers/usb/common/ kernel/drivers/usb/core/ \
kernel/drivers/mmc/ kernel/drivers/block/ kernel/drivers/cdrom/ kernel/fs/fat/ kernel/fs/nls/ \
kernel/fs/squashfs/ kernel/fs/overlayfs/ kernel/fs/isofs/"

out="$RESCUE_OUT"
root="$RESCUE_ROOT_DIR"
initrd="$B/rescue-initramfs"

sudo rm -rf "$root" "$initrd" "$out"
mkdir -p "$out"
sudo cp -a --reflink=auto "$RESCUE_BASE_DIR" "$root"

# 1. Kernel modules of the shared kernel
kver="$(ls "$BASE_DIR/lib/modules")"
sudo mkdir -p "$root/lib/modules"
sudo cp -a "$BASE_DIR/lib/modules/$kver" "$root/lib/modules/"

# 2. Configure
# copied by root without preserving ownership -> files end up root-owned
sudo cp -R --preserve=mode,timestamps "$REPO/rescue/overlay/." "$root/"
echo "$RESCUE_HOSTNAME" | sudo tee "$root/etc/hostname" >/dev/null
printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n::1\t\tlocalhost ip6-localhost ip6-loopback\n' \
    "$RESCUE_HOSTNAME" | sudo tee "$root/etc/hosts" >/dev/null
: | sudo tee "$root/etc/fstab" >/dev/null
echo "root:$RESCUE_ROOT_PASS" | sudo chroot "$root" chpasswd
sudo chroot "$root" systemctl enable -q systemd-networkd systemd-resolved
# WireGuard: the main system's import service (config from the card), with the
# card path set by rescue/overlay/.../maglinux-wireguard-import.service.d/
for f in usr/local/sbin/maglinux-wireguard-import \
         etc/systemd/system/maglinux-wireguard-import.service \
         etc/systemd/system/wg-quick@.service.d/50-maglinux-sdcard.conf \
         etc/systemd/system/systemd-time-wait-sync.service.d/50-maglinux-timeout.conf; do
    sudo install -D -m "$(stat -c %a "$REPO/overlay/$f")" "$REPO/overlay/$f" "$root/$f"
done
sudo chroot "$root" systemctl enable -q wg-quick@wg0.service systemd-time-wait-sync.service
# Per-boot identity: no baked-in machine-id or ssh host keys
: | sudo tee "$root/etc/machine-id" >/dev/null
sudo rm -f "$root"/etc/ssh/ssh_host_*

# 3. Initramfs: static busybox + rescue/init + boot-medium drivers (with dependencies)
mkdir -p "$initrd/bin" "$initrd/lib/modules/$kver"
cp "$root/bin/busybox" "$initrd/bin/busybox"
install -m 755 "$REPO/rescue/init" "$initrd/init"
mdir="$root/lib/modules/$kver"
# shellcheck disable=SC2086  # word splitting of the module list is intended
prefixes="$(echo $RESCUE_INITRAMFS_MODULES | tr ' ' '|')"
awk -F': ?' -v re="^($prefixes)" '$1 ~ re { print $1; n = split($2, d, " "); for (i = 1; i <= n; i++) print d[i] }' \
    "$mdir/modules.dep" | sort -u | while read -r m; do
    install -D -m 644 "$mdir/$m" "$initrd/lib/modules/$kver/$m"
done
cp "$mdir"/modules.order "$mdir"/modules.builtin* "$initrd/lib/modules/$kver/"
# busybox modprobe: use uncompressed modules
find "$initrd/lib/modules" -name '*.ko.xz' -exec unxz {} +
find "$initrd/lib/modules" -name '*.ko.zst' -exec zstd -q -d --rm {} +
depmod -b "$initrd" "$kver"
(cd "$initrd" && find . | cpio -o -H newc --quiet | gzip -9) > "$out/initramfs.gz"

# 4. Read-only root filesystem (kernel lives on the FAT partition; drop apt caches)
sudo mksquashfs "$root" "$out/rescue.sqfs" -noappend -comp xz -quiet \
    -e boot var/cache/apt/archives var/lib/apt/lists
sudo chown "$(id -u):$(id -g)" "$out"/*
ls -lh "$out"
