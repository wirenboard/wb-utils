DESTDIR=/
prefix=usr

ifeq ($(DEB_BUILD_GNU_TYPE),$(DEB_HOST_GNU_TYPE))
       CC=gcc
else
       CC=$(DEB_HOST_GNU_TYPE)-gcc
endif


all: inj
	@echo Nothing to do

BINDIR = $(DESTDIR)/$(prefix)/bin
LIBDIR = $(DESTDIR)/$(prefix)/lib/wb-utils
INITDIR = $(DESTDIR)/etc/init.d

install:
	install -m 0755 -d $(BINDIR) $(LIBDIR) $(INITDIR)
	install -m 0644 board/wb_env.sh $(DESTDIR)/etc/wb_env.sh

	install -m 0644 -t $(LIBDIR) board/*.sh gsm/wb-gsm-common.sh

	install -m 0755 -t $(BINDIR) board/wb-gen-serial board/wb-set-mac
	install -m 0755 -t $(BINDIR) gsm/wb-gsm gsm/wb-gsm-rtc

	install -m 0755 gsm/rtc.init $(INITDIR)/wb-gsm-rtc
	install -m 0755 board/board.init $(INITDIR)/wb-init
	install -m 0755 board/prepare.init $(INITDIR)/wb-prepare

	install -m 0755 -t $(BINDIR) update/wb-run-update update/wb-watch-update
	install -m 0755 update/wb-watch-update.init $(INITDIR)/wb-watch-update


clean:
	@echo Nothing to do

.PHONY: install clean all

# run "debuild" in chroot to make deb package
