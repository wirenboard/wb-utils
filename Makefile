DESTDIR=
prefix=/usr
sysconfdir=/etc

all:
	@echo Nothing to do

SYSCONFDIR = $(DESTDIR)$(sysconfdir)
BINDIR = $(DESTDIR)/$(prefix)/bin
LIBDIR = $(DESTDIR)/$(prefix)/lib/wb-utils
USBOTGDIR = $(LIBDIR)/wb-usb-otg
NMSCDIR = $(DESTDIR)/$(prefix)/lib/NetworkManager/system-connections
PREPARE_LIBDIR = $(LIBDIR)/prepare
IMAGEUPDATE_POSTINST_DIR = $(DESTDIR)$(prefix)/lib/wb-image-update/postinst

install:
	install -Dm0644 utils/etc_wb_env.sh $(SYSCONFDIR)/wb_env.sh

	install -m 0755 -d $(BINDIR) $(LIBDIR) $(PREPARE_LIBDIR) $(IMAGEUPDATE_POSTINST_DIR) $(USBOTGDIR) $(NMSCDIR)

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
		utils/lib/wb-usb-otg/wb-usb-otg-stop.sh

	install -Dm0644 -t $(USBOTGDIR) \
		utils/lib/wb-usb-otg/mass_storage

	install -Dm0600 -t $(NMSCDIR) \
		utils/lib/NetworkManager/system-connections/wb-ecm.nmconnection \
		utils/lib/NetworkManager/system-connections/wb-rndis.nmconnection

clean:
	@echo Nothing to do

.PHONY: install clean all

# run "debuild" in chroot to make deb package
