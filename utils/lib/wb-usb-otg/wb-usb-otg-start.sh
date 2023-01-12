#!/bin/bash

. /usr/lib/wb-utils/wb-usb-otg/wb-usb-otg-common.sh

trap "remove_usb_gadget; exit 1" ERR

log "wb-usb-otg-start"
setup_device
enable_profile
mount_ms
exit 0
