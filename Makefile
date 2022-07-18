DESTDIR=/
prefix=usr


all:
	@echo Nothing to do

BINDIR = $(DESTDIR)/$(prefix)/bin
LIBDIR = $(DESTDIR)/$(prefix)/lib/wb-utils
PREPARE_LIBDIR = $(LIBDIR)/prepare
IMAGEUPDATE_POSTINST_DIR = $(DESTDIR)/$(prefix)/lib/wb-image-update/postinst

install:
	install -m 0755 -d $(BINDIR) $(LIBDIR) $(PREPARE_LIBDIR) $(IMAGEUPDATE_POSTINST_DIR)

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

	install -m 0755 -t $(BINDIR) \
		utils/bin/wb-gen-serial \
		utils/bin/wb-set-mac \
		utils/bin/wb-gsm \
		utils/bin/wb-watch-update \
		utils/bin/wb-run-update

	install -m 0755 -t $(IMAGEUPDATE_POSTINST_DIR) \
		utils/lib/wb-image-update/postinst/10update-u-boot

clean:
	@echo Nothing to do

.PHONY: install clean all

# run "debuild" in chroot to make deb package
