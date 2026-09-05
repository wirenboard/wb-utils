#!/bin/bash

. /usr/lib/wb-utils/wb-usb-otg/wb-usb-otg-common.sh

trap "config_reset; remove_usb_gadget; exit 1" ERR

log "wb-usb-otg-start"
wait_for_nm_connection
# Binding and medium insertion happen in wb-usb-otg-netfunc.service (Wants= from this unit)
setup_device
enable_profile
exit 0
