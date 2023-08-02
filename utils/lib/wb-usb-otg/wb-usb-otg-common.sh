#!/bin/bash

IMAGE_FILE=/usr/lib/wb-utils/wb-usb-otg/mass_storage.img
USBDEV="usb0"
USBGADGET_CONFIG=/sys/kernel/config/usb_gadget/g1
RNDIS_IFNAME="dbg%d"

log() {
    >&2 echo "${FUNCNAME[2]}: $*"
}

setup_usb() {
    mkdir -p ${USBGADGET_CONFIG}

    echo 0x1d6b > ${USBGADGET_CONFIG}/idVendor  # Linux Foundation
    echo 0x0104 > ${USBGADGET_CONFIG}/idProduct # Multifunction Composite Gadget
    echo 0x0100 > ${USBGADGET_CONFIG}/bcdDevice # v1.0.0
    echo 0x0200 > ${USBGADGET_CONFIG}/bcdUSB    # USB 2.0

    echo 0xEF > ${USBGADGET_CONFIG}/bDeviceClass
    echo 0x02 > ${USBGADGET_CONFIG}/bDeviceSubClass
    echo 0x01 > ${USBGADGET_CONFIG}/bDeviceProtocol

    mkdir -p ${USBGADGET_CONFIG}/strings/0x409

    echo "fedcba9876543210" > ${USBGADGET_CONFIG}/strings/0x409/serialnumber
    echo "Wirenboard" > ${USBGADGET_CONFIG}/strings/0x409/manufacturer
    echo "WB7 Debug Network" > ${USBGADGET_CONFIG}/strings/0x409/product

    mkdir ${USBGADGET_CONFIG}/configs/c.1
    echo 250 > ${USBGADGET_CONFIG}/configs/c.1/MaxPower
}

setup_rndis() {
    mkdir -p ${USBGADGET_CONFIG}/functions/rndis.$USBDEV
    echo RNDIS   > ${USBGADGET_CONFIG}/functions/rndis.$USBDEV/os_desc/interface.rndis/compatible_id
    echo 5162001 > ${USBGADGET_CONFIG}/functions/rndis.$USBDEV/os_desc/interface.rndis/sub_compatible_id  # to match Windows
    # fixed macs (to prevent randomly generating on each modprobe)
    # https://www.kernel.org/doc/Documentation/usb/gadget-testing.txt for more info
    echo "1a:55:89:a2:69:44" > ${USBGADGET_CONFIG}/functions/rndis.$USBDEV/host_addr
    echo "1a:55:89:a2:69:43" > ${USBGADGET_CONFIG}/functions/rndis.$USBDEV/dev_addr
    echo $RNDIS_IFNAME > ${USBGADGET_CONFIG}/functions/rndis.$USBDEV/ifname
}

setup_mass_storage() {
    mkdir -p ${USBGADGET_CONFIG}/functions/mass_storage.$USBDEV
    echo 1 > ${USBGADGET_CONFIG}/functions/mass_storage.$USBDEV/stall
    echo 0 > ${USBGADGET_CONFIG}/functions/mass_storage.$USBDEV/lun.0/cdrom
    echo 1 > ${USBGADGET_CONFIG}/functions/mass_storage.$USBDEV/lun.0/ro
    echo 0 > ${USBGADGET_CONFIG}/functions/mass_storage.$USBDEV/lun.0/nofua
}

setup_device() {
    log "setup_device()"

    modprobe usb_f_mass_storage
    modprobe usb_f_rndis

    setup_usb
    setup_mass_storage
    setup_rndis
}

bind_device() {
    	COUNT_OF_FILES=$(($(ls /sys/class/udc -1 | wc -l)))
	if [[ $COUNT_OF_FILES -eq 0 ]]
	then
		log "ERROR! There are no files in /sys/class/udc, unable to bind device"
	else
    	ls /sys/class/udc | head -1 > ${USBGADGET_CONFIG}/UDC
    fi
}

unbind_device() {
    echo "" > ${USBGADGET_CONFIG}/UDC
}

config_reset() {
    if [ -L ${USBGADGET_CONFIG}/os_desc/c.1 ]; then rm ${USBGADGET_CONFIG}/os_desc/c.1; fi
    rm ${USBGADGET_CONFIG}/configs/c.1/mass_storage.$USBDEV
    if [ -L ${USBGADGET_CONFIG}/configs/c.1/rndis.$USBDEV ]; then rm ${USBGADGET_CONFIG}/configs/c.1/rndis.$USBDEV; fi
}

remove_usb_gadget() {
    log "Removing strings from configurations"
    for dir in "${USBGADGET_CONFIG}"/configs/*/strings/*; do
        [ -d "$dir" ] && rmdir "$dir"
    done

    log "Removing functions from configurations"
    for func in "${USBGADGET_CONFIG}"/configs/*.*/*.*; do
        [ -e "$func" ] && rm "$func"
    done

    log "Removing configurations"
    for conf in "${USBGADGET_CONFIG}"/configs/*; do
        [ -d "$conf" ] && rmdir "$conf"
    done

    log "Removing functions"
    for func in "${USBGADGET_CONFIG}"/functions/*.*; do
        [ -d "$func" ] && rmdir "$func"
    done

    log "Removing strings"
    for str in "${USBGADGET_CONFIG}"/strings/*; do
        [ -d "$str" ] && rmdir "$str"
    done

    log "Removing gadget"
    rmdir "${USBGADGET_CONFIG}"
}

config_rndis() {
    ln -s ${USBGADGET_CONFIG}/functions/rndis.$USBDEV/ ${USBGADGET_CONFIG}/configs/c.1/

    # OS descriptors
    echo 1       > ${USBGADGET_CONFIG}/os_desc/use
    echo 0xcd    > ${USBGADGET_CONFIG}/os_desc/b_vendor_code
    echo MSFT100 > ${USBGADGET_CONFIG}/os_desc/qw_sign

    ln -s ${USBGADGET_CONFIG}/configs/c.1 ${USBGADGET_CONFIG}/os_desc
}

mount_ms() {
    echo $IMAGE_FILE > ${USBGADGET_CONFIG}/functions/mass_storage.$USBDEV/lun.0/file
}

enable_profile() {
    log "enabling profile rndis"
    config_rndis
    ln -s ${USBGADGET_CONFIG}/functions/mass_storage.$USBDEV ${USBGADGET_CONFIG}/configs/c.1/
    bind_device
}
