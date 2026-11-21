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

1. **Build the 8GB SD card image:**
   ```bash
   ./scripts/build.sh
   ```
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

