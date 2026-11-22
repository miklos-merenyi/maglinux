#!/bin/bash
# Configure the main system: fresh copy of build/base -> build/rootfs, then apply
# the overlay, users, desktop, VNC and rebuild the initramfs.
. "$(dirname "$(realpath "$0")")/../lib.sh"
. "$CONFIG/settings.sh"

R="$ROOTFS_DIR"
sudo rm -rf "$R"
sudo cp -a --reflink=auto "$BASE_DIR" "$R"

# Git-tracked overlay
sudo cp -r "$REPO/overlay/." "$R/"
# initramfs-tools silently ignores hooks/scripts that are not executable
sudo find "$R/etc/initramfs-tools/hooks" "$R/etc/initramfs-tools/scripts" \
    -type f ! -name ORDER -exec chmod 755 {} +

# fstab, hostname, hosts
echo "/dev/loop0 / btrfs defaults,compress=zstd:3,noatime 0 1" | sudo tee "$R/etc/fstab" >/dev/null
echo "$HOSTNAME_NEW" | sudo tee "$R/etc/hostname" >/dev/null
sudo tee "$R/etc/hosts" >/dev/null <<HOSTS
127.0.0.1	localhost
127.0.1.1	$HOSTNAME_NEW
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
HOSTS

# Root password and default user
sudo chroot "$R" useradd -m -s /bin/bash "$USER_NAME"
for g in sudo audio video plugdev netdev users; do
    if sudo chroot "$R" getent group "$g" >/dev/null; then
        sudo chroot "$R" usermod -aG "$g" "$USER_NAME"
    fi
done
printf '%s\n' "root:$ROOT_PASS" "$USER_NAME:$USER_PASS" | sudo chroot "$R" chpasswd

# The SD card's FAT partition (/run/sdcard, mounted in the initramfs) belongs to the
# default user; the initramfs script reads the numeric ids from this file
printf 'MAGLINUX_SDCARD_UID=%s\nMAGLINUX_SDCARD_GID=%s\n' \
    "$(sudo chroot "$R" id -u "$USER_NAME")" \
    "$(sudo chroot "$R" id -g "$USER_NAME")" \
    | sudo tee "$R/etc/initramfs-tools/conf.d/maglinux-sdcard" >/dev/null

# Passwordless sudo for the default user (validated, a broken sudoers file fails the build)
echo "$USER_NAME ALL=(ALL:ALL) NOPASSWD: ALL" | sudo tee "$R/etc/sudoers.d/$USER_NAME" >/dev/null
sudo chmod 440 "$R/etc/sudoers.d/$USER_NAME"
sudo chroot "$R" visudo -c -q

# Local X: LightDM logs the default user into XFCE automatically
sudo mkdir -p "$R/etc/lightdm/lightdm.conf.d"
sudo tee "$R/etc/lightdm/lightdm.conf.d/50-autologin.conf" >/dev/null <<LIGHTDM
[Seat:*]
autologin-user=$USER_NAME
autologin-user-timeout=0
autologin-session=xfce
LIGHTDM

# VNC password for the default user (~/.vnc/passwd, used by vncserver)
sudo chroot "$R" install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "/home/$USER_NAME/.vnc"
printf '%s\n' "$VNC_PASS" | sudo chroot "$R" vncpasswd -f | sudo tee "$R/home/$USER_NAME/.vnc/passwd" >/dev/null
sudo chroot "$R" chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.vnc/passwd"
sudo chmod 600 "$R/home/$USER_NAME/.vnc/passwd"

# Autostart VNC server on display :1 (port 5901) for the default user, reachable from the network
echo ":1=$USER_NAME" | sudo tee "$R/etc/tigervnc/vncserver.users" >/dev/null
sudo tee -a "$R/etc/tigervnc/vncserver-config-defaults" >/dev/null <<'VNCCFG'

# maglinux: accept connections from the network, default desktop size
$localhost = "no";
$geometry = "1280x800";
1;
VNCCFG
sudo chroot "$R" systemctl enable 'tigervncserver@:1.service'

sudo chroot "$R" update-initramfs -u
