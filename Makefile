# maglinux build: every stage is rebuilt only when its inputs changed.
#
#   make              build build/sdcard-8g.img (default)
#   make <stage>      build up to one stage: base rootfs btrfs rescue-base rescue image
#   make refresh      re-run the Debian bootstraps on the next build (picks up new
#                     package versions, e.g. security updates, without a config change)
#   make run          build if needed, then boot the image in QEMU
#   make clean        remove all build output except the two bootstraps
#   make distclean    remove the whole build directory
#
# Stages (scripts/steps/*.sh; the steps run as your user and use sudo):
#
#   config/packages ─────────> base ──> rootfs ──> rootfs.btrfs ──┐
#                               └─(kernel modules)─┐              ├──> sdcard-8g.img
#   config/rescue-packages ──> rescue-base ──> rescue ────────────┘
#
# base/rescue-base are the slow mmdebstrap runs; rootfs and rescue configure a
# fresh copy of them, so editing the overlay or the settings does not bootstrap again.
# A file *deleted* from overlay/, rescue/ or sdcard/ is not noticed: run `make clean` then.

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
RESCUE_BASE := $(STAMPS)/rescue-base
RESCUE      := $(STAMPS)/rescue
BTRFS       := $(B)/rootfs.btrfs
IMAGE       := $(B)/sdcard-8g.img

tree = $(shell find $(1) -type f)

# Main-system overlay files the rescue system reuses (WireGuard import, NTP wait)
RESCUE_SHARED := overlay/usr/local/sbin/maglinux-wireguard-import \
	overlay/etc/systemd/system/maglinux-wireguard-import.service \
	overlay/etc/systemd/system/wg-quick@.service.d/50-maglinux-sdcard.conf \
	overlay/etc/systemd/system/systemd-time-wait-sync.service.d/50-maglinux-timeout.conf

.PHONY: all base rootfs btrfs rescue-base rescue image refresh run clean distclean
all: image
base: $(BASE)
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

$(ROOTFS): $(BASE) config/settings.sh $(call tree,overlay) $(STEPS)/rootfs.sh $(LIB)
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

refresh:
	rm -f $(BASE) $(RESCUE_BASE)

run: $(IMAGE)
	scripts/run_qemu

clean:
	sudo rm -rf --one-file-system $(B)/rootfs $(B)/rescue-root $(B)/rescue-initramfs $(B)/rescue \
		$(B)/rootfs.btrfs $(B)/sdcard-8g.img $(B)/*.tmp $(ROOTFS) $(RESCUE)

distclean:
	sudo rm -rf --one-file-system $(B)
