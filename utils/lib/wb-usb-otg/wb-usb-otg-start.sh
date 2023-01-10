#!/bin/bash

. /usr/lib/wb-utils/wb-usb-otg/wb-usb-otg-common.sh

log "wb-usr-otg-start"
setup_device
enable_profile "rndis"
mount_ms
nmcli c up "wb-rndis"
exit 0
