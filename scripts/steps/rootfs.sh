#!/bin/bash
# Configure the main system: fresh copy of build/base -> build/rootfs, then apply
# the overlay, users, desktop, VNC and rebuild the initramfs.
. "$(dirname "$(realpath "$0")")/../lib.sh"
. "$CONFIG/settings.sh"

R="$ROOTFS_DIR"
sudo rm -rf "$R"
sudo cp -a --reflink=auto "$BASE_DIR" "$R"

# Git-tracked overlay, except home/ (copied once the default user exists, below)
shopt -s nullglob dotglob
for e in "$REPO"/overlay/*; do
    [[ $(basename "$e") == home ]] || sudo cp -r "$e" "$R/"
done
shopt -u nullglob dotglob
# initramfs-tools silently ignores hooks/scripts that are not executable
sudo find "$R/etc/initramfs-tools/hooks" "$R/etc/initramfs-tools/scripts" \
    -type f ! -name ORDER -exec chmod 755 {} +

# Local packages (debs/*.deb). dpkg does not download anything: their dependencies
# must be listed in config/packages, otherwise the build fails here.
shopt -s nullglob
debs=("$REPO"/debs/*.deb)
shopt -u nullglob
if (( ${#debs[@]} )); then
    sudo mkdir -p "$R/tmp/debs"
    sudo cp "${debs[@]}" "$R/tmp/debs/"
    sudo chroot "$R" sh -c 'dpkg -i /tmp/debs/*.deb'
    sudo rm -rf "$R/tmp/debs"
fi

# Hold the kernel: the card boots the kernel and initrd on the FAT partition (and the
# rescue system has modules for it), so a kernel upgraded by apt would never boot and
# could remove the running kernel's modules. A newer kernel comes with a rebuild
# (make refresh). The installed packages are held, whichever version they are.
mapfile -t kernel_pkgs < <(sudo chroot "$R" dpkg-query -W \
    -f '${db:Status-Abbrev} ${Package}\n' 'linux-image-*' | awk '$1 == "ii" {print $2}')
(( ${#kernel_pkgs[@]} )) || { echo "ERROR: no linux-image package installed" >&2; exit 1; }
sudo chroot "$R" apt-mark hold "${kernel_pkgs[@]}"

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

# overlay/home/<user>/ goes into the default user's home, owned by the user. Copying
# it before useradd would leave the home root-owned and without the /etc/skel files.
for d in "$REPO"/overlay/home/*; do
    [[ $(basename "$d") == "$USER_NAME" ]] || {
        echo "ERROR: overlay/home/$(basename "$d"): only $USER_NAME exists (USER_NAME in config/settings.sh)" >&2
        exit 1
    }
done
if [[ -d $REPO/overlay/home/$USER_NAME ]]; then
    H="$R/home/$USER_NAME"
    sudo cp -r "$REPO/overlay/home/$USER_NAME/." "$H/"
    sudo chroot "$R" chown -R -h "$USER_NAME:$USER_NAME" "/home/$USER_NAME"
    # No group/other write access (symlinks are skipped: chmod would follow them)
    sudo find "$H" -mindepth 1 \( -type d -o -type f \) -exec chmod go-w {} +
fi

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

# WireGuard wg0, configured from the SD card (sdcard/config/wireguard/); the unit
# is skipped while the card has no wg0.conf
sudo chroot "$R" systemctl enable -q wg-quick@wg0.service
# time-sync.target waits for the first NTP sync (wg-quick@ is ordered after it)
sudo chroot "$R" systemctl enable -q systemd-time-wait-sync.service

# GSettings defaults from the overlay (usr/share/glib-2.0/schemas/*.gschema.override)
sudo chroot "$R" glib-compile-schemas --strict /usr/share/glib-2.0/schemas

sudo chroot "$R" update-initramfs -u
