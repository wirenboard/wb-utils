#!/bin/bash

PID_FILE=/var/run/wb-usb-otg.pid
IMAGE_FILE=/usr/lib/wb-utils/wb-usb-otg/mass_storage
PROFILE_FILE=/var/lib/wb-usb-otg.profile
N="usb0"
g=/sys/kernel/config/usb_gadget/g1

log_target() {
    if [ -z "$1" ]; then
        level=info
    else
        level=$1
    fi
    exec systemd-cat -t wb-usb-otg -p $level    
}

log() {
    echo $1
    echo $1 | log_target $2
}

setup_device() {

    log "setup_device()"

    modprobe usb_f_mass_storage
    modprobe usb_f_rndis
    modprobe usb_f_ecm

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

    mkdir -p ${g}/functions/mass_storage.$N
    echo 1 > ${g}/functions/mass_storage.$N/stall
    echo 0 > ${g}/functions/mass_storage.$N/lun.0/cdrom
    echo 1 > ${g}/functions/mass_storage.$N/lun.0/ro
    echo 0 > ${g}/functions/mass_storage.$N/lun.0/nofua


    mkdir -p ${g}/functions/rndis.$N  # network
    echo RNDIS   > ${g}/functions/rndis.$N/os_desc/interface.rndis/compatible_id
    echo 5162001 > ${g}/functions/rndis.$N/os_desc/interface.rndis/sub_compatible_id
    echo "1a:55:89:a2:69:44" > ${g}/functions/rndis.$N/host_addr
    echo "1a:55:89:a2:69:43" > ${g}/functions/rndis.$N/dev_addr
    echo "rndis%d" > ${g}/functions/rndis.$N/ifname

    mkdir -p ${g}/functions/ecm.$N
    echo "1a:55:89:a2:69:42" > ${g}/functions/ecm.$N/host_addr
    echo "1a:55:89:a2:69:41" > ${g}/functions/ecm.$N/dev_addr
    echo "ecm%d" > ${g}/functions/ecm.$N/ifname

    mkdir ${g}/configs/c.1
    echo 250 > ${g}/configs/c.1/MaxPower

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

config_rndis() {
    ln -s ${g}/functions/rndis.$N/ ${g}/configs/c.1/
    ln -s ${g}/functions/mass_storage.$N ${g}/configs/c.1/

    # OS descriptors
    echo 1       > ${g}/os_desc/use
    echo 0xcd    > ${g}/os_desc/b_vendor_code
    echo MSFT100 > ${g}/os_desc/qw_sign

    ln -s ${g}/configs/c.1 ${g}/os_desc
}

config_ecm() {
    ln -s ${g}/functions/ecm.$N/ ${g}/configs/c.1/
    ln -s ${g}/functions/mass_storage.$N ${g}/configs/c.1/
}

nm_down_rndis() {
    nmcli c down wb-rndis
}

nm_down_ecm() {
    nmcli c down wb-ecm
}

nm_up_rndis() {
    nmcli c up wb-rndis
}

nm_up_ecm() {
    nmcli c up wb-ecm
}

mount_ms() {
    echo $IMAGE_FILE > ${g}/functions/mass_storage.$N/lun.0/file
}

get_default_profile() {
    if [ -f $PROFILE_FILE ]; then
	profile=`cat $PROFILE_FILE`
    else
	profile='rndis'
    fi
}

set_default_profile() {
    echo $profile > $PROFILE_FILE
}

disable_profile() {
    log "disabling profile $1"
    if [ "$1" == 'ecm' ]; then
        nm_down_ecm
	unbind_device
        sleep 1
        config_reset
    else
        nm_down_rndis
	unbind_device
        sleep 1
        config_reset
    fi
}

enable_profile() {
    log "enabling profile $1"
    if [ "$1" == 'ecm' ]; then
	config_ecm
        bind_device
        nm_up_ecm
    else
	config_rndis
	bind_device
	nm_up_rndis
    fi
}

switch_config() {
    if [ -L ${g}/configs/c.1/ecm.$N ]; then
	log "current device is ecm, changing to rndis"
        disable_profile ecm
        enable_profile rndis
        profile='rndis'
    else
	log "current device is rndis, changing to ecm"
        disable_profile rndis
        enable_profile ecm
        profile='ecm'
    fi
}

check_interface() {
    sleep 5
    value=`cat /sys/class/net/${profile}0/statistics/rx_packets`
    echo "value = $value"
    if [ "$value" == "0" ]; then
        ifconfig "${profile}0"
	return 1
    else:
	return 0
    fi
}

cycle_loop() {
    check_interface
    if [ $? != 0 ]; then
	log "no ping, changing config"
        switch_config
    else
	log "ping ok"
        mount_ms
        set_default_profile $profile
        rm $PID_FILE
        exit 0
    fi
}

# actual commands

log "wb-usr-otg-start"

if [ ! -f /usr/sbin/NetworkManager ]; then
    log "NetworkManager not found, exiting"
    exit 1
fi

if [ -f $PID_FILE ]; then
    if [ ps --pid `cat $PID_FILE` &>/dev/null ]; then
        log "Another instance is already running"
	exit
    else
	log "Stale PID file detected"
	rm $PID_FILE
    fi
fi
echo $$ > $PID_FILE

#profile=''

#setup_device
#get_default_profile
#log "Default profile is $profile"
#enable_profile $profile

#while :
#do
#    sleep 10
#    cycle_loop
#done

profile='rndis'
setup_device
enable_profile $profile
mount_ms
exit 0