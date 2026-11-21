# shellcheck shell=bash
# Build the Alpine Linux (x86) rescue system. Sourced by build.sh, which provides
# WORK_DIR, safe_umount and the cleanup/trap handling.
#
# Produces in $WORK_DIR/rescue/:
#   vmlinuz         Alpine linux-lts kernel
#   initramfs.gz    busybox initramfs (rescue/init) that mounts rescue.sqfs
#   rescue.sqfs     read-only Alpine root filesystem (OpenRC, sshd)

ALPINE_VER="3.24.4"
ALPINE_BRANCH="v${ALPINE_VER%.*}"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
ALPINE_MINIROOTFS="alpine-minirootfs-${ALPINE_VER}-x86.tar.gz"
ALPINE_MINIROOTFS_SHA256="df793865bf166c10acaad3a4d5d40498f9ee3f89fa405d39c7f540464fb3b0c1"

RESCUE_HOSTNAME="maglinux-rescue"
RESCUE_ROOT_PASS="magroot"
RESCUE_PACKAGES="alpine-base openssh linux-lts linux-firmware-none busybox-static \
btrfs-progs dosfstools e2fsprogs lsblk util-linux-misc"

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
    local cache="$WORK_DIR/cache"

    echo "=== Rescue system: Alpine $ALPINE_VER x86"
    sudo rm -rf "$root" "$initrd" "$out"
    mkdir -p "$out" "$cache/apk"

    # 1. Alpine minirootfs (cached, checksum verified)
    if ! echo "$ALPINE_MINIROOTFS_SHA256  $cache/$ALPINE_MINIROOTFS" | sha256sum -c --quiet >/dev/null 2>&1; then
        curl -fL --retry 3 -o "$cache/$ALPINE_MINIROOTFS" \
            "$ALPINE_MIRROR/$ALPINE_BRANCH/releases/x86/$ALPINE_MINIROOTFS"
        echo "$ALPINE_MINIROOTFS_SHA256  $cache/$ALPINE_MINIROOTFS" | sha256sum -c --quiet
    fi
    sudo mkdir -p "$root"
    sudo tar -xzf "$cache/$ALPINE_MINIROOTFS" -C "$root"

    # 2. Install packages inside the chroot (apk verifies package signatures itself)
    printf '%s\n' "$ALPINE_MIRROR/$ALPINE_BRANCH/main" "$ALPINE_MIRROR/$ALPINE_BRANCH/community" |
        sudo tee "$root/etc/apk/repositories" >/dev/null
    sudo cp -L /etc/resolv.conf "$root/etc/resolv.conf"
    # The rescue initramfs is our own; don't let the kernel package run mkinitfs
    sudo mkdir -p "$root/etc/mkinitfs"
    echo 'disable_trigger="yes"' | sudo tee "$root/etc/mkinitfs/mkinitfs.conf" >/dev/null
    sudo mkdir -p "$root/var/cache/apk"
    sudo mount --bind "$cache/apk" "$root/var/cache/apk"
    for d in proc sys dev; do sudo mount --rbind "/$d" "$root/$d"; sudo mount --make-rslave "$root/$d"; done
    # shellcheck disable=SC2086
    sudo chroot "$root" /sbin/apk add --cache-dir /var/cache/apk $RESCUE_PACKAGES
    for d in dev sys proc var/cache/apk; do safe_umount "$root/$d"; done

    # 3. Configure
    # copied by root without preserving ownership -> files end up root-owned
    sudo cp -R --preserve=mode,timestamps "$repo/rescue/overlay/." "$root/"
    echo "$RESCUE_HOSTNAME" | sudo tee "$root/etc/hostname" >/dev/null
    printf '127.0.0.1\tlocalhost %s\n::1\t\tlocalhost\n' "$RESCUE_HOSTNAME" | sudo tee "$root/etc/hosts" >/dev/null
    echo "root:$RESCUE_ROOT_PASS" | sudo chroot "$root" chpasswd
    sudo rm -f "$root/etc/resolv.conf"
    local svc
    for svc in devfs dmesg mdev hwdrivers sysfs; do sudo chroot "$root" rc-update -q add "$svc" sysinit; done
    for svc in modules sysctl hostname bootmisc syslog networking; do sudo chroot "$root" rc-update -q add "$svc" boot; done
    for svc in sshd; do sudo chroot "$root" rc-update -q add "$svc" default; done
    for svc in mount-ro killprocs; do sudo chroot "$root" rc-update -q add "$svc" shutdown; done

    local kver; kver="$(ls "$root/lib/modules")"
    sudo cp "$root/boot/vmlinuz-lts" "$out/vmlinuz"

    # 4. Initramfs: static busybox + rescue/init + boot-medium drivers (with dependencies)
    mkdir -p "$initrd/bin" "$initrd/lib/modules/$kver"
    cp "$root/bin/busybox.static" "$initrd/bin/busybox"
    install -m 755 "$repo/rescue/init" "$initrd/init"
    local mdir="$root/lib/modules/$kver"
    local prefixes; prefixes="$(echo $RESCUE_INITRAMFS_MODULES | tr ' ' '|')"
    awk -F': ?' -v re="^($prefixes)" '$1 ~ re { print $1; n = split($2, d, " "); for (i = 1; i <= n; i++) print d[i] }' \
        "$mdir/modules.dep" | sort -u | while read -r m; do
        install -D -m 644 "$mdir/$m" "$initrd/lib/modules/$kver/$m"
    done
    cp "$mdir"/modules.order "$mdir"/modules.builtin* "$initrd/lib/modules/$kver/"
    # busybox modprobe: use uncompressed modules
    find "$initrd/lib/modules" -name '*.ko.gz' -exec gunzip {} +
    find "$initrd/lib/modules" -name '*.ko.xz' -exec unxz {} +
    find "$initrd/lib/modules" -name '*.ko.zst' -exec zstd -q -d --rm {} +
    depmod -b "$initrd" "$kver"
    (cd "$initrd" && find . | cpio -o -H newc --quiet | gzip -9) > "$out/initramfs.gz"

    # 5. Read-only root filesystem (kernel lives on the FAT partition, not needed inside)
    sudo mksquashfs "$root" "$out/rescue.sqfs" -noappend -comp xz -quiet \
        -e boot var/cache/apk
    sudo chown "$(id -u):$(id -g)" "$out"/*
    ls -lh "$out"
}
