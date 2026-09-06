#!/bin/bash

IMAGE_FILE=/usr/lib/wb-utils/wb-usb-otg/mass_storage.img
USBDEV="usb0"
USBGADGET_CONFIG=/sys/kernel/config/usb_gadget/g1
RNDIS_IFNAME="dbg%d"
ECM_IFNAME="dbge%d"
# Handed to wb-usb-otg-netfunc.service (EnvironmentFile=): the daemon links the functions
# into the configuration, binds the UDC and publishes the WebUSB landing page.
NETFUNC_ENV_FILE=/run/wb-usb-otg/env
WEBUSB_LANDING_PAGE=
ECM_FUNCTION=
WINUSB_FUNCTION=
NETWORK_CONNAME="wb-debug"
NETWORK_TIMEOUT=5
FFS_WINUSB_NAME="wbwinusb"
# GUID of the stub interface: Windows uses it to create the device interface, without
# which Chrome cannot open the function and read the WebUSB landing page.
WINUSB_DEVICE_INTERFACE_GUID="{9E3C1B4A-7D52-4F86-A1C9-2B7E5D8F3A61}"
MSOS20_VENDOR_CODE=0x02   # must differ from webusb (0x01) and os_desc (0xcd)
MSOS20_GEN=/usr/lib/wb-utils/wb-usb-otg/gen-msos20.py
# Stub interface number: the network function takes 0-1, mass_storage 2 (link order set in
# wb-usb-otg-netfunc.py bind()); the MS OS 2.0 set names the WinUSB interface by this number
FFS_WINUSB_INTERFACE=3
# WebUSB landing page is advertised only when wb-mqtt-homeui has set up HTTPS with a
# trusted certificate (*.<SN>.ip.wirenboard.com); Chromium ignores non-https landing pages.
HOMEUI_HTTPS_CONF=/var/lib/wb-homeui/nginx/https.conf
SHORT_SN_FILE=/var/lib/wirenboard/short_sn.conf

log() {
    >&2 echo "${FUNCNAME[2]}: $*"
}

wait_for_nm_connection() {
    log "Waiting for NM connection ${NETWORK_CONNAME}"

    timeout=${NETWORK_TIMEOUT}
    while [[ ! $(nmcli c | grep ${NETWORK_CONNAME}) ]]; do
        sleep 1
        ((timeout--))
        if [ $timeout -eq 0 ]; then
            log "Timeout waiting for NM connection ${NETWORK_CONNAME}"
            return 1
        fi
    done
    log "NM connection ${NETWORK_CONNAME} is up"
    return 0
}

setup_usb() {
    mkdir -p ${USBGADGET_CONFIG}

    echo 0x1d6b > ${USBGADGET_CONFIG}/idVendor  # Linux Foundation
    echo 0x0104 > ${USBGADGET_CONFIG}/idProduct # Multifunction Composite Gadget
    # v1.0.1: the descriptor layout changed (a WinUSB stub interface was added).
    # Windows caches the MS OS descriptor query result in the registry under
    # usbflags\<VID><PID><bcdDevice>, so without a version bump it may not re-query the
    # compat ID and would not load WinUSB on the new interface.
    # The value must be valid BCD (only 0-9 in every nibble): configfs rejects e.g.
    # 0x010a and falls back to the default. The next revision after 0x0109 is 0x0110.
    echo 0x0101 > ${USBGADGET_CONFIG}/bcdDevice # v1.0.1
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

setup_ecm() {
    # CDC ECM for hosts without an RNDIS driver (macOS). Created here, linked into the
    # configuration by wb-usb-otg-netfunc.py only when the probe finds no RNDIS host:
    # RNDIS + mass storage + ECM do not fit the 4+4 endpoints of the H616 musb together.
    # Optional: without the module the Debug Network keeps working as before (RNDIS only).
    if ! modprobe usb_f_ecm || ! mkdir -p ${USBGADGET_CONFIG}/functions/ecm.$USBDEV; then
        log "usb_f_ecm not available, CDC ECM (macOS) disabled"
        return 0
    fi
    ECM_FUNCTION="ecm.$USBDEV"
    echo "1a:55:89:a2:69:45" > ${USBGADGET_CONFIG}/functions/ecm.$USBDEV/dev_addr
    # Same host MAC as RNDIS: both layouts serve one host on a /30 with a single DHCP
    # lease, and a different MAC would leave dnsmasq with "no address available".
    cat ${USBGADGET_CONFIG}/functions/rndis.$USBDEV/host_addr > ${USBGADGET_CONFIG}/functions/ecm.$USBDEV/host_addr
    echo $ECM_IFNAME > ${USBGADGET_CONFIG}/functions/ecm.$USBDEV/ifname
}

setup_mass_storage() {
    mkdir -p ${USBGADGET_CONFIG}/functions/mass_storage.$USBDEV
    echo 1 > ${USBGADGET_CONFIG}/functions/mass_storage.$USBDEV/stall
    echo 0 > ${USBGADGET_CONFIG}/functions/mass_storage.$USBDEV/lun.0/cdrom
    echo 1 > ${USBGADGET_CONFIG}/functions/mass_storage.$USBDEV/lun.0/ro
    echo 0 > ${USBGADGET_CONFIG}/functions/mass_storage.$USBDEV/lun.0/nofua
}

setup_webusb() {
    # WebUSB platform capability (BOS descriptor + GET_URL vendor request): Chromium
    # shows a "Go to <site> to connect" notification when the controller is plugged in.
    # Needs kernel >= 6.3 (webusb/ group in configfs); the notification additionally
    # requires the kernel to report bcdUSB 0x0210 (patched in 6.8.0-wb162).
    # The landing page https://<debug-ip with dashes>.<sn>.ip.wirenboard.com/ resolves
    # to the debug-network IP and is covered by the wb-mqtt-homeui wildcard certificate.
    local sn ip url

    [ -d ${USBGADGET_CONFIG}/webusb ] || return 0

    if [ ! -f "${HOMEUI_HTTPS_CONF}" ]; then
        log "HTTPS not configured, WebUSB landing page disabled"
        return 0
    fi

    sn=$(cat "${SHORT_SN_FILE}")
    ip=$(nmcli -g ipv4.addresses c show "${NETWORK_CONNAME}" 2>/dev/null | cut -d/ -f1)
    if [ -z "${sn}" ] || [ -z "${ip}" ]; then
        log "short SN ('${sn}') or ${NETWORK_CONNAME} IPv4 address ('${ip}') not available, WebUSB landing page disabled"
        return 0
    fi
    url="https://${ip//./-}.${sn,,}.ip.wirenboard.com/"

    echo 0x01 > ${USBGADGET_CONFIG}/webusb/bVendorCode  # must differ from os_desc/b_vendor_code (0xcd)
    # iLandingPage stays 0 during the host probe (one Chromium notification per plug, not
    # per enumeration); wb-usb-otg-netfunc.py writes the URL once the layout is final.
    WEBUSB_LANDING_PAGE="${url}"
    echo 1 > ${USBGADGET_CONFIG}/webusb/use
    log "WebUSB landing page: ${url}"
}

setup_device() {
    log "setup_device()"

    modprobe usb_f_mass_storage
    modprobe usb_f_rndis

    setup_usb
    setup_webusb
    setup_msos20
    setup_mass_storage
    setup_rndis
    setup_ecm
}

setup_msos20() {
    # MS OS 2.0 descriptor set. Windows 8.1+ reads it from the BOS and IGNORES MS OS 1.0,
    # so the set also describes RNDIS - otherwise RNDIS loses its compat ID and the
    # network breaks. It gives the stub interface a DeviceInterfaceGUID: only with it can
    # Chrome open the function (usb_service_win.cc::GetFunctionInfo) and read the WebUSB
    # landing page. Requires a kernel with msos20/ support in configfs.
    local blob

    [ -d ${USBGADGET_CONFIG}/msos20 ] || return 0
    [ -x ${MSOS20_GEN} ] || { log "${MSOS20_GEN} not found, MS OS 2.0 skipped"; return 0; }

    blob=$(mktemp)
    if ! ${MSOS20_GEN} --winusb-interface ${FFS_WINUSB_INTERFACE} \
            --guid "${WINUSB_DEVICE_INTERFACE_GUID}" -o "${blob}" >/dev/null; then
        log "failed to build the MS OS 2.0 descriptor set"
        rm -f "${blob}"
        return 0
    fi

    echo ${MSOS20_VENDOR_CODE} > ${USBGADGET_CONFIG}/msos20/bVendorCode
    cat "${blob}" > ${USBGADGET_CONFIG}/msos20/descriptor_set
    echo 1 > ${USBGADGET_CONFIG}/msos20/use
    rm -f "${blob}"
    log "MS OS 2.0: WinUSB on interface ${FFS_WINUSB_INTERFACE}, GUID ${WINUSB_DEVICE_INTERFACE_GUID}"
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
    # The function links in c.1 are created by wb-usb-otg-netfunc.py; remove whatever is there
    if [ -L ${USBGADGET_CONFIG}/os_desc/c.1 ]; then rm ${USBGADGET_CONFIG}/os_desc/c.1; fi
    for link in ${USBGADGET_CONFIG}/configs/c.1/*.*; do
        [ -L "$link" ] && rm "$link"
    done
    rm -f ${NETFUNC_ENV_FILE}
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

setup_os_desc() {
    # MS OS 1.0 descriptors (RNDIS compat ID). os_desc/use is toggled per layout by the daemon.
    echo 0xcd    > ${USBGADGET_CONFIG}/os_desc/b_vendor_code
    echo MSFT100 > ${USBGADGET_CONFIG}/os_desc/qw_sign

    ln -s ${USBGADGET_CONFIG}/configs/c.1 ${USBGADGET_CONFIG}/os_desc
}

write_netfunc_env() {
    mkdir -p "$(dirname ${NETFUNC_ENV_FILE})"
    cat > ${NETFUNC_ENV_FILE} <<EOF
USBGADGET_CONFIG=${USBGADGET_CONFIG}
USBDEV=${USBDEV}
IMAGE_FILE=${IMAGE_FILE}
LANDING_PAGE=${WEBUSB_LANDING_PAGE}
ECM_FUNCTION=${ECM_FUNCTION}
WINUSB_FUNCTION=${WINUSB_FUNCTION}
EOF
}

enable_profile() {
    log "enabling profile"
    setup_os_desc
    # WinUSB stub: without it Chromium on Windows cannot read the WebUSB landing page.
    # The unit is restarted here because stopping wb-usb-otg removes the gadget directory
    # together with functions/ffs.*; Type=notify => restart returns once the descriptors
    # have been written. The network and the drive do not depend on this function.
    if systemctl restart wb-usb-otg-winusb.service; then
        WINUSB_FUNCTION="ffs.${FFS_WINUSB_NAME}"
    else
        log "wb-usb-otg-winusb.service failed, WebUSB landing page will not work on Windows"
    fi
    # The functions are linked into c.1 and the UDC is bound by wb-usb-otg-netfunc.service,
    # which picks RNDIS or CDC ECM for the connected host and inserts the mass-storage medium.
    write_netfunc_env
}
