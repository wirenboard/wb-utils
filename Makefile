DESTDIR=/
prefix=usr

ifeq ($(DEB_BUILD_GNU_TYPE),$(DEB_HOST_GNU_TYPE))
       CC=gcc
else
       CC=$(DEB_HOST_GNU_TYPE)-gcc
endif


all:
	@echo Nothing to do

BINDIR = $(DESTDIR)/$(prefix)/bin
LIBDIR = $(DESTDIR)/$(prefix)/lib/wb-utils
PREPARE_LIBDIR = $(LIBDIR)/prepare

install:
	install -m 0755 -d $(BINDIR) $(LIBDIR) $(PREPARE_LIBDIR)

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
		utils/lib/wb-init.sh

	install -m 0655 -t $(PREPARE_LIBDIR) \
		utils/lib/prepare/partitions.sh \
		utils/lib/prepare/vars.sh

	install -m 0755 -t $(PREPARE_LIBDIR) \
		utils/lib/prepare/wb-prepare.sh

	install -m 0755 -t $(BINDIR) \
		utils/bin/wb-gen-serial \
		utils/bin/wb-set-mac \
		utils/bin/wb-gsm \
		utils/bin/wb-gsm-rtc \
		utils/bin/wb-watch-update \
		utils/bin/wb-run-update

clean:
	@echo Nothing to do

.PHONY: install clean all

# run "debuild" in chroot to make deb package
