#!/bin/bash

IMAGE_FILE=/usr/lib/wb-utils/wb-usb-otg/mass_storage
N="usb0"
g=/sys/kernel/config/usb_gadget/g1
RNDIS_IFNAME="rndis%d"
ECM_IFNAME="ecm%d"

log() {
    >&2 echo "${FUNCNAME[2]}: $*"
}

setup_usb() {
    mkdir -p ${g}

    echo 0x1d6b > ${g}/idVendor  # Linux Foundation
    echo 0x0104 > ${g}/idProduct # Multifunction Composite Gadget
    echo 0x0100 > ${g}/bcdDevice # v1.0.0
    echo 0x0200 > ${g}/bcdUSB    # USB 2.0

    echo 0xEF > ${g}/bDeviceClass
    echo 0x02 > ${g}/bDeviceSubClass
    echo 0x01 > ${g}/bDeviceProtocol

    mkdir -p ${g}/strings/0x409

    echo "fedcba9876543210" > ${g}/strings/0x409/serialnumber
    echo "Wirenboard" > ${g}/strings/0x409/manufacturer
    echo "WB7 Debug Network" > ${g}/strings/0x409/product

    mkdir ${g}/configs/c.1
    echo 250 > ${g}/configs/c.1/MaxPower
}

setup_rndis() {
    mkdir -p ${g}/functions/rndis.$N
    echo RNDIS   > ${g}/functions/rndis.$N/os_desc/interface.rndis/compatible_id
    echo 5162001 > ${g}/functions/rndis.$N/os_desc/interface.rndis/sub_compatible_id
    echo "1a:55:89:a2:69:44" > ${g}/functions/rndis.$N/host_addr
    echo "1a:55:89:a2:69:43" > ${g}/functions/rndis.$N/dev_addr
    echo $RNDIS_IFNAME > ${g}/functions/rndis.$N/ifname
}

setup_ecm() {
    mkdir -p ${g}/functions/ecm.$N
    echo "1a:55:89:a2:69:42" > ${g}/functions/ecm.$N/host_addr
    echo "1a:55:89:a2:69:41" > ${g}/functions/ecm.$N/dev_addr
    echo $ECM_IFNAME > ${g}/functions/ecm.$N/ifname
}

setup_mass_storage() {
    mkdir -p ${g}/functions/mass_storage.$N
    echo 1 > ${g}/functions/mass_storage.$N/stall
    echo 0 > ${g}/functions/mass_storage.$N/lun.0/cdrom
    echo 1 > ${g}/functions/mass_storage.$N/lun.0/ro
    echo 0 > ${g}/functions/mass_storage.$N/lun.0/nofua
}

setup_device() {
    log "setup_device()"

    modprobe usb_f_mass_storage
    modprobe usb_f_rndis
    modprobe usb_f_ecm

    setup_usb
    setup_mass_storage
    setup_rndis
    setup_ecm
}

bind_device() {
    echo musb-hdrc.2.auto > ${g}/UDC
}

unbind_device() {
    echo "" > ${g}/UDC
}

config_reset() {
    if [ -L ${g}/os_desc/c.1 ]; then rm ${g}/os_desc/c.1; fi
    rm ${g}/configs/c.1/mass_storage.$N
    if [ -L ${g}/configs/c.1/ecm.$N ]; then rm ${g}/configs/c.1/ecm.$N; fi
    if [ -L ${g}/configs/c.1/rndis.$N ]; then rm ${g}/configs/c.1/rndis.$N; fi

}

remove_usb_gadget() {
    log "Removing strings from configurations"
    for dir in ${g}/configs/*/strings/*; do
        [ -d $dir ] && rmdir $dir
    done

    log "Removing functions from configurations"
    for func in ${g}/configs/*.*/*.*; do
        [ -e $func ] && rm $func
    done

    log "Removing configurations"
    for conf in ${g}/configs/*; do
        [ -d $conf ] && rmdir $conf
    done

    log "Removing functions"
    for func in ${g}/functions/*.*; do
        [ -d $func ] && rmdir $func
    done

    log "Removing strings"
    for str in ${g}/strings/*; do
        [ -d $str ] && rmdir $str
    done

    log "Removing gadget"
    rmdir ${g}
}

config_rndis() {
    ln -s ${g}/functions/rndis.$N/ ${g}/configs/c.1/

    # OS descriptors
    echo 1       > ${g}/os_desc/use
    echo 0xcd    > ${g}/os_desc/b_vendor_code
    echo MSFT100 > ${g}/os_desc/qw_sign

    ln -s ${g}/configs/c.1 ${g}/os_desc
}

config_ecm() {
    ln -s ${g}/functions/ecm.$N/ ${g}/configs/c.1/
}

mount_ms() {
    echo $IMAGE_FILE > ${g}/functions/mass_storage.$N/lun.0/file
}

enable_profile() {
    log "enabling profile $1"
    if [ "$1" == "ecm" ]; then
        config_ecm
    else
        config_rndis
    fi
    ln -s ${g}/functions/mass_storage.$N ${g}/configs/c.1/
    bind_device
}
