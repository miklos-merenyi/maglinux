#!/bin/bash
set -eEuo pipefail

# The host's locale (e.g. en_IE.UTF-8) does not exist inside the chroot; use C
# so perl/apt/dpkg in the chroot don't print "Setting locale failed" warnings.
# sudo passes LANG/LANGUAGE/LC_* through, so this also reaches the chroot.
export LC_ALL=C LANG=C LANGUAGE=

# Running as a normal user: Debian leaves the sbin dirs out of a user's PATH, but
# tools run without sudo (mkfs.btrfs, parted, depmod, ...) live there.
export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"

# Run as a normal user: privileged steps use sudo. Ask for the password once up front
# and keep the sudo timestamp fresh, so the long bootstrap step does not prompt again.
sudo -v
( while sleep 50; do sudo -n -v 2>/dev/null || exit; done ) &
SUDO_KEEPALIVE_PID=$!

IMG_NAME="sdcard-8g.img"
BTRFS_IMG="rootfs.btrfs"

# System identity / credentials
HOSTNAME_NEW="maglinux"
USER_NAME="maguser"
USER_PASS="maguser"
VNC_PASS="maguser"
ROOT_PASS="magroot"

# APT sources for the built systems (also written to their /etc/apt/sources.list):
# release + stable updates + security updates
DEBIAN_SOURCES=(
    "deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://deb.debian.org/debian bookworm main non-free-firmware"
    "deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://deb.debian.org/debian bookworm-updates main non-free-firmware"
    "deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://security.debian.org/debian-security bookworm-security main non-free-firmware"
)
WORK_DIR="./build"
mkdir -p "$WORK_DIR"
WORK_DIR="$(realpath "$WORK_DIR")"
# Images are created as the invoking user; make sure the work dir is ours
# (older builds run entirely as root left it root-owned)
sudo chown "$(id -u):$(id -g)" "$WORK_DIR"

# Unmount a mountpoint (and anything mounted below it); fall back to lazy umount if busy
safe_umount() {
    local m="$1"
    mountpoint -q "$m" 2>/dev/null || return 0
    sync
    sudo umount -R "$m" 2>/dev/null || { sleep 1; sudo umount -R "$m" 2>/dev/null; } || {
        echo "WARN: $m busy, using lazy unmount" >&2
        sudo umount -R -l "$m" || true
    }
}

# Tear down everything this (or a previous, failed) run may have left behind
cleanup() {
    local -   # keep the "set +e" below local to this function (restored on return)
    set +e
    # Anything mounted inside our work dir (mnt_fat, mnt_btrfs, rootfs/proc, ...)
    grep -F " $WORK_DIR/" /proc/mounts | awk '{print $2}' | sort -r | while read -r m; do
        safe_umount "$m"
    done
    # Loop devices backed by our images (also catches "(deleted)" image files)
    for f in "$IMG_NAME" "$BTRFS_IMG"; do
        sudo losetup -a | grep -F "$WORK_DIR/$f" | cut -d: -f1 | while read -r dev; do
            sudo kpartx -d "$dev" 2>/dev/null
            for p in /dev/mapper/"$(basename "$dev")"p*; do
                [[ -e $p ]] && sudo dmsetup remove "$p" 2>/dev/null
            done
            sudo losetup -d "$dev" 2>/dev/null
        done
    done
    # Stale device-mapper partitions whose loop device is already gone
    for p in /dev/mapper/loop*p*; do
        [[ -e $p ]] || continue
        dev="/dev/$(basename "$p" | sed 's/p[0-9]*$//')"
        sudo losetup "$dev" >/dev/null 2>&1 || sudo dmsetup remove "$p" 2>/dev/null
    done
    sudo udevadm settle 2>/dev/null
    return 0
}

on_exit() {
    local rc=$?
    trap - EXIT INT TERM ERR
    cleanup
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    if [[ $rc -ne 0 ]]; then
        echo "Build FAILED (exit $rc) - mounts and loop devices have been cleaned up." >&2
    fi
    exit $rc
}
on_error() {
    echo "ERROR: command failed at line $1: $2" >&2
}

# Rescue system (build_rescue)
# shellcheck source=scripts/rescue.sh
. "$(dirname "$(realpath "$0")")/rescue.sh"

cleanup
trap on_exit EXIT
trap 'exit 130' INT TERM
trap 'on_error $LINENO "$BASH_COMMAND"' ERR

sudo rm -rf "$WORK_DIR/rootfs" "$WORK_DIR/$BTRFS_IMG" "$WORK_DIR/$IMG_NAME"

# 1. Bootstrap Debian 12 i386
sudo mmdebstrap --arch=i386 --variant=minbase \
    --aptopt='Apt::Install-Recommends "false";' \
    --aptopt='Acquire::http::Proxy "http://127.0.0.1:3142";' \
    --include="linux-image-686,firmware-realtek,systemd-sysv,btrfs-progs,initramfs-tools,syslinux,dosfstools,udev,kmod,ifupdown,isc-dhcp-client,openssh-server,zstd,xfce4,xfce4-terminal,dbus-x11,tigervnc-standalone-server,tigervnc-tools,network-manager,network-manager-gnome,polkitd,logrotate,sudo,mc,xserver-xorg-core,xserver-xorg-video-vesa,xserver-xorg-video-fbdev,xserver-xorg-video-intel,xserver-xorg-input-libinput,lightdm,lightdm-gtk-greeter" \
    bookworm "$WORK_DIR/rootfs" "${DEBIAN_SOURCES[@]}"

# The apt proxy (apt-cacher-ng on the build host) is only reachable during the build;
# mmdebstrap stores --aptopt settings in the target, so remove it there.
sudo sed -i '/Acquire::http::Proxy/d' "$WORK_DIR/rootfs/etc/apt/apt.conf.d/99mmdebstrap"

# 2. Apply Git-tracked overlays & configure fstab
sudo cp -r "$(dirname "$(realpath "$0")")/../overlay/." "$WORK_DIR/rootfs/"
# initramfs-tools silently ignores hooks/scripts that are not executable
sudo find "$WORK_DIR/rootfs/etc/initramfs-tools/hooks" "$WORK_DIR/rootfs/etc/initramfs-tools/scripts" \
    -type f ! -name ORDER -exec chmod 755 {} +
echo "/dev/loop0 / btrfs defaults,compress=zstd:3,noatime 0 1" | sudo tee "$WORK_DIR/rootfs/etc/fstab" >/dev/null
echo "$HOSTNAME_NEW" | sudo tee "$WORK_DIR/rootfs/etc/hostname" >/dev/null
sudo tee "$WORK_DIR/rootfs/etc/hosts" >/dev/null <<HOSTS
127.0.0.1	localhost
127.0.1.1	$HOSTNAME_NEW
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
HOSTS

# Root password and default user
sudo chroot "$WORK_DIR/rootfs" useradd -m -s /bin/bash "$USER_NAME"
for g in sudo audio video plugdev netdev users; do
    if sudo chroot "$WORK_DIR/rootfs" getent group "$g" >/dev/null; then
        sudo chroot "$WORK_DIR/rootfs" usermod -aG "$g" "$USER_NAME"
    fi
done
printf '%s\n' "root:$ROOT_PASS" "$USER_NAME:$USER_PASS" | sudo chroot "$WORK_DIR/rootfs" chpasswd

# Passwordless sudo for the default user (validated, a broken sudoers file fails the build)
echo "$USER_NAME ALL=(ALL:ALL) NOPASSWD: ALL" | sudo tee "$WORK_DIR/rootfs/etc/sudoers.d/$USER_NAME" >/dev/null
sudo chmod 440 "$WORK_DIR/rootfs/etc/sudoers.d/$USER_NAME"
sudo chroot "$WORK_DIR/rootfs" visudo -c -q

# Local X: LightDM logs the default user into XFCE automatically
sudo mkdir -p "$WORK_DIR/rootfs/etc/lightdm/lightdm.conf.d"
sudo tee "$WORK_DIR/rootfs/etc/lightdm/lightdm.conf.d/50-autologin.conf" >/dev/null <<LIGHTDM
[Seat:*]
autologin-user=$USER_NAME
autologin-user-timeout=0
autologin-session=xfce
LIGHTDM

# VNC password for the default user (~/.vnc/passwd, used by vncserver)
sudo chroot "$WORK_DIR/rootfs" install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "/home/$USER_NAME/.vnc"
printf '%s\n' "$VNC_PASS" | sudo chroot "$WORK_DIR/rootfs" vncpasswd -f | sudo tee "$WORK_DIR/rootfs/home/$USER_NAME/.vnc/passwd" >/dev/null
sudo chroot "$WORK_DIR/rootfs" chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.vnc/passwd"
sudo chmod 600 "$WORK_DIR/rootfs/home/$USER_NAME/.vnc/passwd"

# Autostart VNC server on display :1 (port 5901) for the default user, reachable from the network
echo ":1=$USER_NAME" | sudo tee "$WORK_DIR/rootfs/etc/tigervnc/vncserver.users" >/dev/null
sudo tee -a "$WORK_DIR/rootfs/etc/tigervnc/vncserver-config-defaults" >/dev/null <<'VNCCFG'

# maglinux: accept connections from the network, default desktop size
$localhost = "no";
$geometry = "1280x800";
1;
VNCCFG
sudo chroot "$WORK_DIR/rootfs" systemctl enable 'tigervncserver@:1.service'

sudo chroot "$WORK_DIR/rootfs" update-initramfs -u

# 3. Create compressed Btrfs image (6GB max capacity, sparse file)
truncate -s 3800M "$WORK_DIR/$BTRFS_IMG"
mkfs.btrfs -f -L DEBIAN_ROOT "$WORK_DIR/$BTRFS_IMG"

mkdir -p "$WORK_DIR/mnt_btrfs"
sudo mount -o loop,compress=zstd:3 "$WORK_DIR/$BTRFS_IMG" "$WORK_DIR/mnt_btrfs"
sudo cp -a "$WORK_DIR/rootfs/." "$WORK_DIR/mnt_btrfs/"
safe_umount "$WORK_DIR/mnt_btrfs"

# 4. Debian rescue system -> $WORK_DIR/rescue/{initramfs.gz,rescue.sqfs}
build_rescue

# 5. Build the 8GB vfat SD card image
truncate -s 7500M "$WORK_DIR/$IMG_NAME" # Slightly under 8GB to fit any 8GB SD card
parted -s "$WORK_DIR/$IMG_NAME" mklabel msdos
parted -s "$WORK_DIR/$IMG_NAME" mkpart primary fat32 1MiB 100%
parted -s "$WORK_DIR/$IMG_NAME" set 1 boot on

# Attach image on a fresh loop device with partition scanning
LOOP_DEV=$(sudo losetup -f -P --show "$WORK_DIR/$IMG_NAME")
PART_DEV="${LOOP_DEV}p1"
sudo udevadm settle
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

# Rescue system and boot menu (menu modules must match the installed syslinux version)
sudo mkdir -p "$WORK_DIR/mnt_fat/rescue"
sudo cp "$WORK_DIR/rescue/initramfs.gz" "$WORK_DIR/rescue/rescue.sqfs" "$WORK_DIR/mnt_fat/rescue/"
sudo cp /usr/lib/syslinux/modules/bios/menu.c32 /usr/lib/syslinux/modules/bios/libutil.c32 \
    "$WORK_DIR/mnt_fat/"

sudo tee "$WORK_DIR/mnt_fat/syslinux.cfg" > /dev/null <<EOF
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

safe_umount "$WORK_DIR/mnt_fat"
sudo losetup -d "$LOOP_DEV"
# Write Syslinux MBR
dd bs=440 count=1 conv=notrunc if=/usr/lib/syslinux/mbr/mbr.bin of="$WORK_DIR/$IMG_NAME"

echo "Build complete: $WORK_DIR/$IMG_NAME"
