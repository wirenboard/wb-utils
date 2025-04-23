DESTDIR=
prefix=/usr
sysconfdir=/etc

all:
	@echo Nothing to do

BINDIR = $(DESTDIR)$(prefix)/bin
LIBDIR = $(DESTDIR)$(prefix)/lib/wb-utils
SYSCONFDIR = $(DESTDIR)$(sysconfdir)
USBOTGDIR = $(LIBDIR)/wb-usb-otg
MASS_STORAGE_FNAME = build_scripts/mass_storage.img
MASS_STORAGE_CONTENT_DIR = utils/lib/wb-usb-otg/mass_storage_contents
NM_DISPATCHER_DIR = $(DESTDIR)$(prefix)/lib/NetworkManager/dispatcher.d
PREPARE_LIBDIR = $(LIBDIR)/prepare

IMAGEUPDATE_DIR=$(DESTDIR)$(prefix)/lib/wb-image-update
IMAGEUPDATE_POSTINST_DIR = $(IMAGEUPDATE_DIR)/postinst
FIT_FILES_DIR=$(IMAGEUPDATE_DIR)/fit

build_mass_storage: export wb_ipaddr := http://10.200.200.1
build_mass_storage:
	$(foreach file, $(wildcard $(MASS_STORAGE_CONTENT_DIR)/*.jinja), j2 -o $(basename $(file)) $(file);)
	GLOBIGNORE=$(MASS_STORAGE_CONTENT_DIR)/*.jinja \
		build_scripts/create-mass-storage-image.sh $(MASS_STORAGE_CONTENT_DIR)/ $(MASS_STORAGE_FNAME)

install: build_mass_storage
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
		utils/lib/ensure-env-cache.sh \
		utils/lib/device-factory-fdt.sh

	install -Dm0655 -t $(PREPARE_LIBDIR) \
		utils/lib/prepare/partitions.sh \
		utils/lib/prepare/vars.sh

	install -Dm0755 -t $(PREPARE_LIBDIR) \
		utils/lib/prepare/wb-prepare.sh

	install -Dm0755 -t $(BINDIR) \
		utils/bin/wb-gen-serial \
		utils/bin/wb-set-mac \
		utils/bin/wb-gsm \
		utils/bin/wb-gsm-mm \
		utils/bin/wb-factoryreset \
		utils/bin/wb-watch-update \
		utils/bin/wb-run-update

	install -Dm0755 -t $(IMAGEUPDATE_DIR) \
		utils/lib/wb-image-update/fix-broken-fit.sh

	install -Dm0755 -t $(IMAGEUPDATE_POSTINST_DIR) \
		utils/lib/wb-image-update/postinst/10update-u-boot \
		utils/lib/wb-image-update/postinst/10update-wbec-firmware

	install -Dm0755 -t $(IMAGEUPDATE_POSTINST_DIR) \
		utils/lib/wb-image-update/postinst/20ms-license

	install -Dm0755 -t $(FIT_FILES_DIR) \
		utils/lib/wb-image-update/fit/build.sh \
		utils/lib/wb-image-update/fit/install_update.sh

	install -Dm0755 -t $(USBOTGDIR) \
		utils/lib/wb-usb-otg/wb-usb-otg-common.sh \
		utils/lib/wb-usb-otg/wb-usb-otg-start.sh \
		utils/lib/wb-usb-otg/wb-usb-otg-stop.sh \
		utils/lib/wb-usb-otg/check-if-supports-usb-network.sh

	install -Dm0644 -t $(USBOTGDIR) \
		$(MASS_STORAGE_FNAME)

	install -Dm0755 -t $(NM_DISPATCHER_DIR) \
		utils/lib/wb-usb-otg/15-debug-network

clean:
	rm -f $(MASS_STORAGE_FNAME)

.PHONY: install clean all

# run "debuild" in chroot to make deb package
