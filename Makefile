DESTDIR=
prefix=/usr
sysconfdir=/etc

all:
	@echo Nothing to do

BINDIR = $(DESTDIR)$(prefix)/bin
LIBDIR = $(DESTDIR)$(prefix)/lib/wb-utils
SYSCONFDIR = $(DESTDIR)$(sysconfdir)
PREPARE_LIBDIR = $(LIBDIR)/prepare
IMAGEUPDATE_POSTINST_DIR = $(DESTDIR)$(prefix)/lib/wb-image-update/postinst
USBOTGDIR = $(LIBDIR)/wb-usb-otg
NMSCDIR = $(DESTDIR)$(prefix)/lib/NetworkManager/system-connections
NMCONFDIR = $(DESTDIR)$(prefix)/lib/NetworkManager/conf.d

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

	install -Dm0644 -t $(USBOTGDIR) \
		utils/lib/wb-usb-otg/mass_storage

	install -Dm0600 -t $(NMSCDIR) \
		utils/lib/NetworkManager/system-connections/wb-ecm.nmconnection \
		utils/lib/NetworkManager/system-connections/wb-rndis.nmconnection

	install -Dm0600 -t $(NMCONFDIR) \
		utils/lib/NetworkManager/80-usbnetwork.conf

clean:
	@echo Nothing to do

.PHONY: install clean all

# run "debuild" in chroot to make deb package
