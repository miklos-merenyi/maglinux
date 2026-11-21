# shellcheck shell=bash
# Build the Debian 12 (i386) rescue system. Sourced by build.sh, which provides
# WORK_DIR, safe_umount and the cleanup/trap handling.
#
# The rescue system boots the main system's kernel (/vmlinuz on the FAT partition),
# so its kernel modules are copied from the main rootfs ($WORK_DIR/rootfs).
#
# Produces in $WORK_DIR/rescue/:
#   initramfs.gz    busybox initramfs (rescue/init) that mounts rescue.sqfs
#   rescue.sqfs     read-only Debian root filesystem (systemd, sshd)

RESCUE_HOSTNAME="maglinux-rescue"
RESCUE_ROOT_PASS="magroot"
RESCUE_PACKAGES="systemd-sysv,udev,kmod,systemd-resolved,openssh-server,busybox-static,\
firmware-realtek,btrfs-progs,dosfstools,e2fsprogs,fdisk,iproute2,iputils-ping,procps,less,nano"

# Modules the initramfs needs to find and mount the boot medium
RESCUE_INITRAMFS_MODULES="kernel/drivers/ata/ kernel/drivers/scsi/ kernel/drivers/usb/host/ \
kernel/drivers/usb/storage/ kernel/drivers/usb/common/ kernel/drivers/usb/core/ \
kernel/drivers/mmc/ kernel/drivers/block/ kernel/drivers/cdrom/ kernel/fs/fat/ kernel/fs/nls/ \
kernel/fs/squashfs/ kernel/fs/overlayfs/ kernel/fs/isofs/"

build_rescue() {
    local repo; repo="$(dirname "$(realpath "$0")")/.."
    local out="$WORK_DIR/rescue"
    local root="$WORK_DIR/rescue-root"
    local initrd="$WORK_DIR/rescue-initramfs"
    local main="$WORK_DIR/rootfs"

    echo "=== Rescue system: Debian 12 i386"
    sudo rm -rf "$root" "$initrd" "$out"
    mkdir -p "$out"

    # 1. Minimal Debian root filesystem
    sudo mmdebstrap --arch=i386 --variant=minbase \
        --aptopt='Apt::Install-Recommends "false";' \
        --aptopt='Acquire::http::Proxy "http://127.0.0.1:3142";' \
        --include="$RESCUE_PACKAGES" \
        bookworm "$root" "${DEBIAN_SOURCES[@]}"

    # Build-host apt proxy must not end up in the image
    sudo sed -i '/Acquire::http::Proxy/d' "$root/etc/apt/apt.conf.d/99mmdebstrap"

    # Kernel modules of the shared kernel
    local kver; kver="$(ls "$main/lib/modules")"
    sudo mkdir -p "$root/lib/modules"
    sudo cp -a "$main/lib/modules/$kver" "$root/lib/modules/"

    # 2. Configure
    # copied by root without preserving ownership -> files end up root-owned
    sudo cp -R --preserve=mode,timestamps "$repo/rescue/overlay/." "$root/"
    echo "$RESCUE_HOSTNAME" | sudo tee "$root/etc/hostname" >/dev/null
    printf '127.0.0.1\tlocalhost\n127.0.1.1\t%s\n::1\t\tlocalhost ip6-localhost ip6-loopback\n' \
        "$RESCUE_HOSTNAME" | sudo tee "$root/etc/hosts" >/dev/null
    : | sudo tee "$root/etc/fstab" >/dev/null
    echo "root:$RESCUE_ROOT_PASS" | sudo chroot "$root" chpasswd
    sudo chroot "$root" systemctl enable -q systemd-networkd systemd-resolved
    # Per-boot identity: no baked-in machine-id or ssh host keys
    : | sudo tee "$root/etc/machine-id" >/dev/null
    sudo rm -f "$root"/etc/ssh/ssh_host_*

    # 3. Initramfs: static busybox + rescue/init + boot-medium drivers (with dependencies)
    mkdir -p "$initrd/bin" "$initrd/lib/modules/$kver"
    cp "$root/bin/busybox" "$initrd/bin/busybox"
    install -m 755 "$repo/rescue/init" "$initrd/init"
    local mdir="$root/lib/modules/$kver"
    local prefixes; prefixes="$(echo $RESCUE_INITRAMFS_MODULES | tr ' ' '|')"
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
}
