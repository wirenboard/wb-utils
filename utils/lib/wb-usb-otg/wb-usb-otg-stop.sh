#!/bin/bash

. /usr/lib/wb-utils/wb-usb-otg/wb-usb-otg-common.sh

log "wb-usb-otg-stop"
unbind_device
config_reset
remove_usb_gadget
