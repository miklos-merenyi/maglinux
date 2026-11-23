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
* **The rescue system brings up the same tunnel**, from the same
  `config/wireguard/wg0.conf` on the card. Both systems use the same key, so only
  one of them can be up at a time, which is always the case on one device.
* **More tunnels:** add `wg1.conf` to the card and run `sudo systemctl enable wg-quick@wg1` on
  the device.
