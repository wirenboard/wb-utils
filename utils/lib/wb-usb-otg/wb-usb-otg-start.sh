#!/bin/bash

. /usr/lib/wb-utils/wb-usb-otg/wb-usb-otg-common.sh

trap "config_reset; remove_usb_gadget; exit 1" ERR

log "wb-usb-otg-start"
wait_for_nm_connection
setup_device
enable_profile
mount_ms
exit 0
