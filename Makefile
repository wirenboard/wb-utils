DESTDIR=/
prefix=usr

all: 
	@echo Nothing to do


install:
	install -m 0644 board/wb_env.sh $(DESTDIR)/etc/wb_env.sh
	install -m 0755 board/wb-gen-serial $(DESTDIR)/$(prefix)/bin/wb-gen-serial
	install -m 0755 board/wb-set-mac $(DESTDIR)/$(prefix)/bin/wb-set-mac

	install -m 0755 gsm/wb-gsm $(DESTDIR)/$(prefix)/bin/wb-gsm
	install -m 0755 gsm/wb-gsm-common.sh $(DESTDIR)/$(prefix)/lib/wb-gsm-common.sh

	install -m 0755 gsm/rtc.sh $(DESTDIR)/$(prefix)/bin/wb-gsm-rtc

	install -m 0755 gsm/rtc.init $(DESTDIR)/etc/init.d/wb-gsm-rtc
	install -m 0755 board/board.init $(DESTDIR)/etc/init.d/wb-init
	install -m 0755 board/prepare.init $(DESTDIR)/etc/init.d/wb-prepare

	install -m 0755 update/wb-run-update $(DESTDIR)/$(prefix)/bin/wb-run-update
	install -m 0755 update/wb-watch-update $(DESTDIR)/$(prefix)/bin/wb-watch-update
	install -m 0755 update/wb-watch-update.init $(DESTDIR)/etc/init.d/wb-watch-update


clean:
	@echo Nothing to do

.PHONY: install clean all

# run "debuild" in chroot to make deb package
