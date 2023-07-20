DESTDIR=/
prefix=usr


all:
	@echo Nothing to do

BINDIR = $(DESTDIR)/$(prefix)/bin
LIBDIR = $(DESTDIR)/$(prefix)/lib/wb-utils
PREPARE_LIBDIR = $(LIBDIR)/prepare
RTC_LIBDIR = $(LIBDIR)/wb-gsm-rtc

IMAGEUPDATE_DIR=$(DESTDIR)$(prefix)/lib/wb-image-update
IMAGEUPDATE_POSTINST_DIR = $(IMAGEUPDATE_DIR)/postinst
FIT_FILES_DIR=$(IMAGEUPDATE_DIR)/fit

install:
	install -m 0755 -d $(BINDIR) $(LIBDIR) $(PREPARE_LIBDIR) $(RTC_LIBDIR) $(IMAGEUPDATE_POSTINST_DIR)

	install -m 0644 utils/etc_wb_env.sh $(DESTDIR)/etc/wb_env.sh

	install -m 0644 -t $(LIBDIR) \
		utils/lib/common.sh \
		utils/lib/hardware.sh \
		utils/lib/json.sh \
		utils/lib/of.sh \
		utils/lib/wb_env_legacy.sh \
		utils/lib/wb_env.sh \
		utils/lib/wb_env_of.sh \
		utils/lib/wb-gsm-common.sh

	install -m 0755 -t $(LIBDIR) \
		utils/lib/wb-init.sh \
		utils/lib/ensure-env-cache.sh

	install -m 0655 -t $(PREPARE_LIBDIR) \
		utils/lib/prepare/partitions.sh \
		utils/lib/prepare/vars.sh

	install -m 0755 -t $(PREPARE_LIBDIR) \
		utils/lib/prepare/wb-prepare.sh

	install -m 0755 -t $(RTC_LIBDIR) \
		utils/lib/wb-gsm-rtc/restore-wrapper.sh \
		utils/lib/wb-gsm-rtc/save-wrapper.sh

	install -m 0755 -t $(BINDIR) \
		utils/bin/wb-gen-serial \
		utils/bin/wb-set-mac \
		utils/bin/wb-gsm \
		utils/bin/wb-gsm-rtc \
		utils/bin/wb-watch-update \
		utils/bin/wb-run-update

	install -m 0755 -t $(IMAGEUPDATE_POSTINST_DIR) \
		utils/lib/wb-image-update/postinst/10update-u-boot

	install -Dm0755 -t $(FIT_FILES_DIR) \
		utils/lib/wb-image-update/fit/build.sh \
		utils/lib/wb-image-update/fit/install_update.sh

clean:
	@echo Nothing to do

.PHONY: install clean all

# run "debuild" in chroot to make deb package
