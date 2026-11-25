# Host Build Environment Setup (Linux Mint)

This document covers the host-level packages, keyrings, and services required on **Linux Mint** to build and test the Debian 12 (`bookworm`) `i386` SD card image. These dependencies live on the build machine and are not tracked inside this Git repository.

---

## 1. Required Host Packages

Install the tools needed for bootstrapping Debian, creating Btrfs/FAT32 filesystems, installing the Syslinux bootloader, and running QEMU tests:

```bash
sudo apt update
sudo apt install -y \
    mmdebstrap \
    debian-archive-keyring \
    btrfs-progs \
    dosfstools \
    mtools \
    syslinux \
    syslinux-common \
    parted \
    kpartx \
    squashfs-tools \
    qemu-system-x86 \
    apt-cacher-ng \
    git \
    make
```

### Why These Are Needed
* **`mmdebstrap` & `debian-archive-keyring`:** Linux Mint does not ship with Debian's repository GPG keys by default. `debian-archive-keyring` provides `/usr/share/keyrings/debian-archive-keyring.gpg` so `mmdebstrap` can verify `bookworm` packages.
* **`btrfs-progs`, `dosfstools`, `mtools`:** Create and manipulate the compressed `rootfs.btrfs` image and the `vfat` (FAT32) SD card partition.
* **`syslinux` & `syslinux-common`:** Provides the `syslinux` installer and `/usr/lib/syslinux/mbr/mbr.bin` required to make the raw disk image bootable.
* **`parted` & `kpartx`:** Partition the raw disk image and map partitions to `/dev/mapper/loop*` devices during the build.
* **`qemu-system-x86`:** Provides `qemu-system-i386` with KVM acceleration for testing the generated image locally.

---

## 2. Local Package Cache (`apt-cacher-ng`)

The build script routes `apt` traffic through `http://127.0.0.1:3142` via `mmdebstrap` (`--aptopt='Acquire::http::Proxy "http://127.0.0.1:3142";'`) so repeated builds do not re-download `.deb` packages from the internet.

Ensure the caching proxy service is enabled and running on the host:

```bash
sudo systemctl enable --now apt-cacher-ng
```

*(Note: During `apt-cacher-ng` installation, if prompted whether to allow HTTP tunnels, choose **No**.)*

### Verify the Cache Service
```bash
systemctl status apt-cacher-ng
```
* **Cache location on host:** `/var/cache/apt-cacher-ng/`
* **Web admin/stats interface:** `http://127.0.0`

---

## 3. QEMU / KVM Permissions

To run `qemu-system-i386 -enable-kvm` without `sudo`, ensure your user belongs to the `kvm` group:

```bash
sudo usermod -aG kvm "\$USER"
```
*(Log out and back in for group membership changes to take effect.)*

---

## 4. Quick Start

Once the host prerequisites above are installed:

1. **Build the 8GB SD card image** (run as your normal user; the steps use `sudo`):
   ```bash
   make
   ```
   `make` only reruns the build stages whose inputs changed; see
   [section 5](#5-build-system).
2. **Test the image in QEMU (with VNC port `5901` forwarded):**
   ```bash
   qemu-system-i386 \
       -enable-kvm \
       -m 1024 \
       -drive file=build/sdcard-8g.img,format=raw,if=ide \
       -netdev user,id=net0,hostfwd=tcp::5901-:5901 \
       -device e1000,netdev=net0 \
       -nographic
   ```
3. **Write to a physical 8GB SD card** *(replace `/dev/sdX` with your actual SD card device)*:
   ```bash
   sudo dd if=build/sdcard-8g.img of=/dev/sdX bs=4M status=progress conv=fsync
   ```
   A larger card works too: on the first boot the initramfs grows the FAT partition
   to the end of the card, up to `FAT_MAX_SIZE` (`config/settings.sh`). The FAT
   tables are already sized for that at build time, so only the size fields in the
   MBR and the boot sector change; no data is moved.

---

## 5. Build System

The build is a `Makefile` that runs one script per stage (`scripts/steps/*.sh`).
Run it as your normal user; the steps call `sudo` themselves. A stage is rebuilt
only when one of its inputs changed.

### Stages

```
config/packages ─────────> base ──> rootfs ──> rootfs.btrfs ──┐
                            └─(kernel modules)─┐              ├──> sdcard-8g.img
config/rescue-packages ──> rescue-base ──> rescue ────────────┘
```

* **`base` / `rescue-base`:** the slow `mmdebstrap` runs that download and install the
  Debian packages (`build/base`, `build/rescue-base`). These trees are never modified.
* **`rootfs` / `rescue`:** take a fresh copy of the matching base and apply the
  overlay, users, passwords, desktop and VNC settings (`build/rootfs`), or build the
  rescue initramfs and `rescue.sqfs` (`build/rescue/`). Changing the configuration
  therefore never triggers a new Debian bootstrap.
* **`btrfs`:** packs `build/rootfs` into the compressed `build/rootfs.btrfs`.
* **`image`:** assembles the bootable `build/sdcard-8g.img`.

### What a change rebuilds

| You change | Stages rerun |
|---|---|
| a file in `overlay/` or `config/settings.sh` | rootfs, btrfs, image |
| a `.deb` in `debs/` | rootfs, btrfs, image |
| a file in `rescue/` or `config/rescue-settings.sh` | rescue, image |
| `config/packages` | base, rootfs, btrfs, rescue (for the kernel modules), image |
| `config/sources.list`, or after `make refresh` | everything |
| nothing | nothing |

### Configuration (`config/`)

| File | Contents |
|---|---|
| `packages` | Packages of the main system, one per line (`#` comments allowed) |
| `rescue-packages` | Packages of the rescue system |
| `sources.list` | APT sources used for the bootstrap and written into the images |
| `settings.sh` | Hostname, user name, passwords, image sizes |
| `rescue-settings.sh` | Rescue system hostname and root password |

Every `.deb` in `debs/` is installed into the main system with `dpkg -i` in the
`rootfs` stage (e.g. `maglin`, into `/opt/maglin`). `dpkg` does not download
anything, so the packages' dependencies must be listed in `config/packages`
(for `maglin`: `libgtkmm-2.4-1v5`, `libglade2-0`); a missing one fails the build.
To update a package, replace the old `.deb` with the new one: deleting a file is
not noticed by `make`, so run `make clean` if you only remove one.

Files in `overlay/` are copied into the main system's root. `overlay/home/maguser/`
(the default user, `USER_NAME`) is copied after the user is created and is owned
by the user; another directory under `overlay/home/` fails the build.

Files in `sdcard/` are copied as-is onto the SD card's FAT partition (mounted at
`/run/sdcard` on the device, owned by the default user).

### Targets

| Command | Effect |
|---|---|
| `make` | Build `build/sdcard-8g.img`, rerunning only what changed |
| `make <stage>` | Build up to one stage: `base`, `rootfs`, `btrfs`, `rescue-base`, `rescue`, `image` |
| `make refresh` | Bootstrap both systems again on the next build, to pick up new Debian package versions (e.g. security updates) when no config file changed |
| `make run` | Build if needed, then boot the image in QEMU (`scripts/run_qemu`) |
| `make clean` | Remove all build output except the two bootstraps |
| `make distclean` | Remove the whole `build/` directory |

Set `APT_PROXY=` (empty) to download packages directly instead of through
`apt-cacher-ng`, e.g. `APT_PROXY= make`.

### Notes

* **The kernel is held on the device** (`apt-mark hold`): the card boots the kernel and
  initrd on its FAT partition, so a kernel upgraded by apt would never boot. A newer
  kernel comes with a rebuild (`make refresh && make`), which holds that version.
* **A file deleted from `overlay/`, `rescue/` or `sdcard/` is not noticed** (only changed and new
  files are). Run `make clean` after deleting one.
* **The two bootstraps need extra disk space**, roughly 1.5 GB in total, because they
  are kept next to the configured copies.
* **An interrupted build never leaves a finished-looking image:** images are built
  under a `.tmp` name and renamed when complete, and each step unmounts and detaches
  its own loop devices on exit.
* `make clean` and `make distclean` use `rm --one-file-system`, so they do not delete
  into anything still mounted inside `build/`.

---

## 6. WireGuard

The tunnel is configured from the SD card, so it can be set up from any PC
without booting the device:

1. On the card's FAT partition, copy `config/wireguard/wg0.conf.example` to
   `config/wireguard/wg0.conf` and fill in the keys, addresses and endpoint.
2. Boot the device. `maglinux-wireguard-import.service` copies every
   `config/wireguard/*.conf` to `/etc/wireguard/` (root only, Windows line endings
   removed), then `wg-quick@wg0` brings up the tunnel.

* **No `wg0.conf` on the card:** `wg-quick@wg0` is skipped without an error.
* **The card is the source of truth:** deleting `wg0.conf` from it removes the
  imported copy on the next boot.
* **After editing on the running device** (`/run/sdcard/config/wireguard/wg0.conf`):
  `sudo systemctl restart wg-quick@wg0` imports it again.
* **Do not add a `DNS =` line:** `resolvconf` is not installed, and `wg-quick` fails with it.
* **The clock must be right:** the server rejects handshakes with a timestamp older
  than the last one it saw. The main system has no NTP: maglin sets the clock from
  GPS and writes it to the hardware clock, which the kernel reads at boot, so the
  tunnel starts with the hardware clock's time. The rescue system waits for the
  first NTP sync (`systemd-timesyncd`, outgoing UDP port 123), at most 2 minutes.
* **The rescue system brings up the same tunnel**, from the same
  `config/wireguard/wg0.conf` on the card. Both systems use the same key, so only
  one of them can be up at a time, which is always the case on one device.
* **More tunnels:** add `wg1.conf` to the card and run `sudo systemctl enable wg-quick@wg1` on
  the device.

---

## 7. Pendrives

A pendrive plugged in while maguser's XFCE session runs is mounted at
`/media/maguser/<label>` (thunar-volman and udisks2; FAT, exFAT and NTFS).
No window opens; Thunar shows the drive in its side pane, where it can be ejected.

* **Settings:** maguser's `~/.config/xfce4/xfconf/xfce-perchannel-xml/thunar-volman.xml`
  (from `overlay/home/maguser/`), or Settings → Removable Drives and Media.
* **No password:** `/etc/polkit-1/rules.d/50-plugdev-udisks2.rules` lets the `plugdev`
  group mount, eject and power off removable drives, also over SSH.
* **Safe removal:** the eject button next to the drive in Thunar's side pane, or in a
  terminal `udisksctl unmount -b /dev/sdX1 && udisksctl power-off -b /dev/sdX` (no
  password) or `sudo eject /dev/sdX` (`eject` needs root for the device).
* **Only on hot-plug:** a pendrive that is already in the device when it boots is not
  mounted automatically; click it in Thunar's side pane.
* **Desktop launchers:** with gvfs, XFCE asks before running a launcher that is not
  marked as trusted. `/usr/local/lib/maglinux/trust-launchers` marks the MagLin
  launchers at every login (`~/.config/autostart/maglinux-trust-launchers.desktop`).

---

## 8. VNC

The local desktop (display `:0`, the automatic login of maguser) is shared over VNC
on port **5901**; there is no separate VNC desktop. A VNC viewer and the screen of
the device show the same session, with one mouse and keyboard.

* **Password:** `VNC_PASS` in `config/settings.sh` (VNC passwords have at most 8
  characters), stored in `/etc/X11/vncpasswd` (root only).
* **How:** TigerVNC's Xorg module (`tigervnc-xorg-extension`), loaded by
  `/etc/X11/xorg.conf.d/50-maglinux-vnc.conf`; the port and the password are set there.
* **Change the password on the device:** `sudo vncpasswd /etc/X11/vncpasswd`, then
  log out or reboot (the password is read when X starts).
* **Resolution:** the device's own screen resolution.
* **On/off:** the "VNC On/Off" icon on maguser's desktop asks, then switches remote
  access without a password (polkit, local session) and without restarting the
  desktop: "off" drops port 5901 with an nftables rule and closes open VNC
  connections. The choice is kept across reboots. From a terminal:
  `sudo maglinux-vnc on|off|status`.

---

## 9. Hostname

The hostname comes from `config/hostname.cfg` on the SD card's FAT partition
(`/run/sdcard/config/hostname.cfg` on the device), so it can be changed from any PC.
The image writes it with `HOSTNAME_NEW` from `config/settings.sh`.

* **Format:** the first line that is not empty or a `#` comment; letters, digits and
  hyphens, at most 63 characters (it is lowercased). Windows line endings are fine.
* **Applied at every boot** by `maglinux-hostname.service`, before the network (DHCP
  sends the name) and before the desktop: the hostname, `/etc/hostname`, the
  `127.0.1.1` line of `/etc/hosts` and the VNC desktop name.
* **Rescue system:** the same name with `-rescue` appended (e.g. `petofi9mon-rescue`).
* **Missing file or invalid name:** the hostname stays as it is; the reason is in
  `journalctl -u maglinux-hostname`.
* **After editing on the device:** reboot. Restarting the service would change the
  name under the running desktop.
