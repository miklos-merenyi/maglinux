# maglinux build: every stage is rebuilt only when its inputs changed.
#
#   make              build build/sdcard-8g.img (default)
#   make <stage>      build up to one stage: base kmod rootfs btrfs rescue-base rescue image
#   make update       build/update/: the update set for a device (copy its contents to
#                     the card's root; applied at the next boot, see README)
#   make refresh      re-run the Debian bootstraps on the next build (picks up new
#                     package versions, e.g. security updates, without a config change)
#   make run          build if needed, then boot the image in QEMU
#   make clean        remove all build output except the bootstraps (and build/kbuild)
#   make distclean    remove the whole build directory
#
# Stages (scripts/steps/*.sh; the steps run as your user and use sudo):
#
#   config/packages ─────────> base ──> rootfs ──> rootfs.btrfs ──┐
#                               └─(kernel modules)─┐              ├──> sdcard-8g.img
#   config/rescue-packages ──> rescue-base ──> rescue ────────────┘
#
# kmod compiles the out-of-tree kernel modules (third_party/) for base's kernel in a
# build chroot (build/kbuild, bootstrapped again only for a new kernel); rootfs
# installs them.
# base/rescue-base are the slow mmdebstrap runs; rootfs and rescue configure a
# fresh copy of them, so editing the overlay or the settings does not bootstrap again.
# A file *deleted* from overlay/, rescue/ or sdcard/ is not noticed: run `make clean` then.
# Local .deb packages in debs/ are installed into the rootfs (a new or changed one
# reruns rootfs; their dependencies belong in config/packages).

SHELL := /bin/bash
.DELETE_ON_ERROR:
.SUFFIXES:

B      := build
STAMPS := $(B)/.stamps
STEPS  := scripts/steps
LIB    := scripts/lib.sh

# Stage outputs (directory trees are represented by stamp files)
BASE        := $(STAMPS)/base
ROOTFS      := $(STAMPS)/rootfs
KMOD        := $(STAMPS)/kmod
RESCUE_BASE := $(STAMPS)/rescue-base
RESCUE      := $(STAMPS)/rescue
BTRFS       := $(B)/rootfs.btrfs
IMAGE       := $(B)/sdcard-8g.img

# Files and symlinks of a tree. With -L (--check-symlink-times) a symlink counts with
# its own mtime, so one that only resolves on the device (e.g. into /run/sdcard) works.
MAKEFLAGS += -L
tree = $(shell find $(1) ! -type d)

# Main-system overlay files the rescue system reuses (WireGuard import, hostname, network)
RESCUE_SHARED := overlay/usr/local/sbin/maglinux-wireguard-import \
	overlay/etc/systemd/system/maglinux-wireguard-import.service \
	overlay/etc/systemd/system/wg-quick@.service.d/50-maglinux-sdcard.conf \
	overlay/usr/local/sbin/maglinux-hostname \
	overlay/etc/systemd/system/maglinux-hostname.service \
	overlay/usr/local/sbin/maglinux-network \
	overlay/etc/systemd/system/maglinux-network.service

.PHONY: all base kmod rootfs btrfs rescue-base rescue image update refresh run clean distclean
all: image
base: $(BASE)
kmod: $(KMOD)
rootfs: $(ROOTFS)
btrfs: $(BTRFS)
rescue-base: $(RESCUE_BASE)
rescue: $(RESCUE)
image: $(IMAGE)

$(STAMPS):
	mkdir -p $@

$(BASE): config/packages config/sources.list $(STEPS)/base.sh $(LIB) | $(STAMPS)
	$(STEPS)/base.sh main
	touch $@

# Out-of-tree kernel modules (third_party/), compiled for the kernel in build/base
$(KMOD): $(BASE) config/sources.list $(call tree,third_party) $(STEPS)/kmod.sh $(LIB) | $(STAMPS)
	$(STEPS)/kmod.sh
	touch $@

$(ROOTFS): $(BASE) $(KMOD) config/settings.sh $(call tree,overlay) $(wildcard debs/*.deb) $(STEPS)/rootfs.sh $(LIB)
	$(STEPS)/rootfs.sh
	touch $@

$(BTRFS): $(ROOTFS) config/settings.sh $(STEPS)/btrfs.sh $(LIB)
	$(STEPS)/btrfs.sh

$(RESCUE_BASE): config/rescue-packages config/sources.list $(STEPS)/base.sh $(LIB) | $(STAMPS)
	$(STEPS)/base.sh rescue
	touch $@

$(RESCUE): $(RESCUE_BASE) $(BASE) config/rescue-settings.sh $(call tree,rescue) $(RESCUE_SHARED) $(STEPS)/rescue.sh $(LIB)
	$(STEPS)/rescue.sh
	touch $@

$(IMAGE): $(BTRFS) $(RESCUE) $(ROOTFS) config/settings.sh $(call tree,sdcard) $(STEPS)/image.sh $(LIB)
	$(STEPS)/image.sh

# The update set, in the card's layout: kernel, initrd, rescue system and main system
# of this build as *.new, and update.sha256 with their checksums
# (scripts/local-top/mount-btrfs-loop checks and applies them at boot)
update: $(BTRFS) $(RESCUE) $(ROOTFS)
	rm -rf $(B)/update
	mkdir -p $(B)/update/boot $(B)/update/rescue
	cp $(B)/rootfs/boot/vmlinuz-* $(B)/update/boot/vmlinuz.new
	cp $(B)/rootfs/boot/initrd.img-* $(B)/update/boot/initrd.img.new
	cp $(B)/rescue/initramfs.gz $(B)/update/rescue/initramfs.gz.new
	cp $(B)/rescue/rescue.sqfs $(B)/update/rescue/rescue.sqfs.new
	cp $(BTRFS) $(B)/update/rootfs.btrfs.new
	cd $(B)/update && sha256sum boot/vmlinuz.new boot/initrd.img.new rescue/initramfs.gz.new \
		rescue/rescue.sqfs.new rootfs.btrfs.new > update.sha256
	@echo "Update set: $(B)/update/ (copy its contents to the root of the device's SD card)"

refresh:
	rm -f $(BASE) $(RESCUE_BASE)

run: $(IMAGE)
	scripts/run_qemu

clean:
	sudo rm -rf --one-file-system $(B)/rootfs $(B)/rescue-root $(B)/rescue-initramfs $(B)/rescue \
		$(B)/rootfs.btrfs $(B)/sdcard-8g.img $(B)/*.tmp $(B)/update $(B)/kmod \
		$(ROOTFS) $(RESCUE) $(KMOD)

distclean:
	sudo rm -rf --one-file-system $(B)
