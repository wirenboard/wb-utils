#!/bin/bash

. /usr/lib/wb-utils/wb-usb-otg/wb-usb-otg-common.sh

log "wb-usb-otg-stop"
unbind_device 2>/dev/null || true  # not bound when wb-usb-otg-netfunc never ran
config_reset
remove_usb_gadget
