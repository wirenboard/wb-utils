DESTDIR=
prefix=/usr
sysconfdir=/etc

all:
	@echo Nothing to do

BINDIR = $(DESTDIR)$(prefix)/bin
LIBDIR = $(DESTDIR)$(prefix)/lib/wb-utils
SYSCONFDIR = $(DESTDIR)$(sysconfdir)
USBOTGDIR = $(LIBDIR)/wb-usb-otg
PREPARE_LIBDIR = $(LIBDIR)/prepare
IMAGEUPDATE_POSTINST_DIR = $(DESTDIR)$(prefix)/lib/wb-image-update/postinst

install:
	install -Dm0644 utils/etc_wb_env.sh $(SYSCONFDIR)/wb_env.sh

	install -Dm0644 -t $(LIBDIR) \
		utils/lib/common.sh \
		utils/lib/hardware.sh \
		utils/lib/json.sh \
		utils/lib/of.sh \
		utils/lib/wb_env_legacy.sh \
		utils/lib/wb_env.sh \
		utils/lib/wb_env_of.sh \
		utils/lib/wb-gsm-common.sh

	install -Dm0755 -t $(LIBDIR) \
		utils/lib/wb-init.sh \
		utils/lib/ensure-env-cache.sh

	install -Dm0655 -t $(PREPARE_LIBDIR) \
		utils/lib/prepare/partitions.sh \
		utils/lib/prepare/vars.sh

	install -Dm0755 -t $(PREPARE_LIBDIR) \
		utils/lib/prepare/wb-prepare.sh

	install -Dm0755 -t $(BINDIR) \
		utils/bin/wb-gen-serial \
		utils/bin/wb-set-mac \
		utils/bin/wb-gsm \
		utils/bin/wb-watch-update \
		utils/bin/wb-run-update

	install -Dm0755 -t $(IMAGEUPDATE_POSTINST_DIR) \
		utils/lib/wb-image-update/postinst/10update-u-boot

	install -Dm0755 -t $(USBOTGDIR) \
		utils/lib/wb-usb-otg/wb-usb-otg-common.sh \
		utils/lib/wb-usb-otg/wb-usb-otg-start.sh \
		utils/lib/wb-usb-otg/wb-usb-otg-stop.sh \
		utils/lib/wb-usb-otg/check-wb7.sh

	build_scripts/create-mass-storage-image.sh utils/lib/wb-usb-otg/mass_storage_contents/ build_scripts/mass_storage.img
	install -Dm0644 -t $(USBOTGDIR) \
		build_scripts/mass_storage.img

clean:
	rm -f build_scripts/mass_storage.img

.PHONY: install clean all

# run "debuild" in chroot to make deb package
