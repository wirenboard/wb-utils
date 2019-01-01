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
PREPARE_LIBDIR = $(DESTDIR)/$(prefix)/lib/wb-prepare
INITDIR = $(DESTDIR)/etc/init.d

install:
	install -m 0755 -d $(BINDIR) $(LIBDIR) $(INITDIR) $(PREPARE_LIBDIR)

	install -m 0644 board/etc_wb_env.sh $(DESTDIR)/etc/wb_env.sh
	install -m 0644 -t $(LIBDIR) board/common.sh board/hardware.sh \
				  board/json.sh board/of.sh board/wb_env_legacy.sh \
				  board/wb_env.sh board/wb_env_of.sh  gsm/wb-gsm-common.sh

	install -m 0755 -t $(BINDIR) board/wb-gen-serial board/wb-set-mac
	install -m 0755 -t $(BINDIR) gsm/wb-gsm gsm/wb-gsm-rtc

	install -m 0755 gsm/rtc.init $(INITDIR)/wb-gsm-rtc
	install -m 0755 board/board.init $(INITDIR)/wb-init
	install -m 0755 board/prepare.init $(INITDIR)/wb-prepare
	install -m 0644 board/partitions.sh $(PREPARE_LIBDIR)/partitions.sh
	install -m 0644 board/vars.sh $(PREPARE_LIBDIR)/vars.sh

	install -m 0755 -t $(BINDIR) update/wb-run-update update/wb-watch-update
	install -m 0755 update/wb-watch-update.init $(INITDIR)/wb-watch-update


clean:
	@echo Nothing to do

.PHONY: install clean all

# run "debuild" in chroot to make deb package
