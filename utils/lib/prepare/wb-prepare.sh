#!/bin/bash -e

ROOT_PARTITION=$(mount -l | grep " / " | cut -d " " -f1)

# legacy: load log_*_msg functions
# once upon a time this script was an init.d script
. /lib/lsb/init-functions

# some constants for convenience
. /usr/lib/wb-utils/prepare/vars.sh
. /usr/lib/wb-utils/prepare/partitions.sh

MB=1024*1024

WB_DIR="/var/lib/wirenboard"
SERIAL="$WB_DIR/serial.conf"
SHORT_SN_FNAME="$WB_DIR/short_sn.conf"

WB_HOSTNAME_PREFIX="${WB_HOSTNAME_PREFIX:-wirenboard}"

FIRSTBOOT_NEED_REBOOT=false

wb_check_mounted()
{
    grep "$1" /proc/mounts 2>&1 >/dev/null
}

wb_erase_partition()
{
    local part=${WB_STORAGE}p$1
    local start=`wb_get_partition_start $1`

    log_action_begin_msg "Erasing partition $part"
    dd if=/dev/zero of=$WB_STORAGE seek=$start bs=$WB_SECTOR_SIZE count=$[1*MB/WB_SECTOR_SIZE] 2>&1 >/dev/null
    log_end_msg $?
}

# Run mkfs.ext4 with custom options
# Args:
# - device file
# - label (optional)
wb_mkfs_ext4()
{
    local dev=$1
    local label=$2

    [[ -e "$dev" ]] || {
        log_failure_msg "Device $dev not found"
        return 1
    }

    log_action_begin_msg "Formatting $dev ($label)"
    yes | mkfs.ext4 -E stride=2,stripe-width=1024 -b 4096 -L "$label" "$dev"
    log_end_msg $?
}

wb_check_alt_rootfs()
{
    local ret=0
    local active_part=`fw_printenv mmcpart | sed 's#.*=##'`
    [[ -n "$active_part" ]] || {
        log_failure_msg "Unable to determine active rootfs partition"
        return 1
    }

    case "$active_part" in
        2)
            alt_part=3
            ;;
        3)
            alt_part=2
            ;;
        *)
            log_failure_msg "Unable to determine second rootfs partition (current is $active_part)"
            return 1
            ;;
    esac
    active_part=${WB_STORAGE}p${active_part}
    alt_part=${WB_STORAGE}p${alt_part}

    local mnt_rootfs_dst=`mktemp -d`

    mount ${alt_part} ${mnt_rootfs_dst} 2>&1 >/dev/null && {
        log_action_msg "Alternative rootfs seems good"
        umount ${mnt_rootfs_dst}
    } || {
        log_warning_msg "Alternative rootfs is unusable, disabling rootfs switching"
        fw_setenv upgrade_available 0
    }
#        wb_mkfs_ext4 ${alt_part} rootfs || return $?
#
#        mount ${alt_part} ${mnt_rootfs_dst} || {
#            log_failure_msg "Unable to mount ${alt_part}"
#            return 1
#        }
#
#        log_action_begin_msg "Copying active rootfs to alternative partition"
#        local mnt_rootfs_src=`mktemp -d`
#        mount --bind / $mnt_rootfs_src &&
#        cp -a $mnt_rootfs_src/. $mnt_rootfs_dst &&
#        umount $mnt_rootfs_src
#        rm -rf $mnt_rootfs_src
#        log_end_msg $?
#        ret=$?
#    }
    rm -rf ${mnt_rootfs_dst}

    return $ret
}

wb_check_swap()
{
    local swap=${WB_STORAGE}p5
    grep ${swap} /proc/swaps 2>&1 >/dev/null && return 0

    [[ -e "${swap}" ]] || {
        log_failure_msg "Swap device $swap not found"
        return 1
    }

    log_action_begin_msg "Creating swap"
    mkswap ${WB_STORAGE}p5 &&
    swapon -a
    log_end_msg $?
}

wb_check_data()
{
    local data=${WB_STORAGE}p6
    wb_check_mounted ${data} && {
        return 0
    }

    # QUICKFIX: sometimes this script accidentially
    # formats a good partition only because is was not
    # mounted at the moment. This problem was detected
    # at WB6 stretch. To prevent this, we just don't allow
    # script to format data partition.
    #
    # In case user really need to format data partition,
    # he can use factory reset feature while updating.
    #
    # wb_mkfs_ext4 ${data} data || return $?

    mkdir -p /mnt/data
    mount ${data} /mnt/data || {
        log_failure_msg "Can't mount ${data}"
        return 1
    }
    return 0
}

wb_prepare_filesystems()
{
    log_action_msg "Preparing filesystems"

    log_action_begin_msg "Resizing root filesystem"
    resize2fs $ROOT_PARTITION >/dev/null
    log_end_msg $?

    wb_check_swap

    wb_check_alt_rootfs
}

wb_fix_file()
{
    local file=$1
    local descr=$2
    local cmd=$3

    if [[ ! -f ${file} ]] || [[ ! -s ${file} ]]; then
        log_action_begin_msg "Creating ${descr}"

        if [[ -e "/mnt/data/${file}" ]] && [[ ! "/mnt/data/${file}" -ef "${file}" ]] ; then
            log_action_cont_msg "found at /mnt/data"
            cp "/mnt/data/${file}" "${file}"
        else
            $cmd ${@:4} > $1
        fi

        log_end_msg $?
    fi
}

wb_gen_mac()
{
    local ethid=$1

    if [[ "${ethid}" == "0" ]]; then
        if [[ -e "${SERIAL}" ]]; then
            log_action_cont_msg "found at ${SERIAL}" >&2
            cat ${SERIAL}
        elif [[ -e "/mnt/data/${SERIAL}" ]]; then
            log_action_cont_msg "found at /mnt/data/${SERIAL}" >&2
            cat "/mnt/data/${SERIAL}"
        else
            wb-gen-serial -m ${ethid}
        fi
    else
        wb-gen-serial -m ${ethid}
    fi
}

wb_fix_macs()
{
    local eth0_mac="$WB_DIR/eth0_mac.conf"
    local eth1_mac="$WB_DIR/eth1_mac.conf"

    wb_fix_file ${eth0_mac} "eth0 MAC address" wb_gen_mac 0
    wb_fix_file ${eth1_mac} "eth1 MAC address" wb_gen_mac 1

    return 0
}

wb_fix_serial()
{
    wb_fix_file ${SERIAL} "old eth0 MAC aka serial.conf" wb-gen-serial -m
}

wb_fix_hosts()
{
    hostname=$(cat /etc/hostname)
    if [[ $hostname =~ ${WB_HOSTNAME_PREFIX}-[0-9A-Z]{2,8} ]]; then
        hostname_search_string=$(awk -v hostname_pattern="$hostname" '$0~hostname_pattern {f=1} $0!~hostname_pattern {f=0} f {print 0}' /etc/hosts.wb)
        if [ -z "$hostname_search_string" ]; then
            sed -i "1i 127.0.0.1    ${hostname}" /etc/hosts.wb
            systemd-cat echo "Add $hostname to /etc/hosts.wb list"
        fi
    fi
}

wb_fix_short_sn()
{
    wb_fix_file ${SHORT_SN_FNAME} "short serial number" wb-gen-serial -s

    # also fill everything containing this short serial number
    local short_sn=`cat ${SHORT_SN_FNAME}`
    local ssid="WirenBoard-${short_sn}"
    local hostname="${WB_HOSTNAME_PREFIX}-${short_sn}"

    log_action_msg "Creating hostname file with ${hostname}"
    if which hostnamectl >/dev/null; then
        hostnamectl set-hostname --static $hostname
        hostnamectl set-chassis embedded
    else
        echo "$hostname" > /etc/hostname.wb
        FIRSTBOOT_NEED_REBOOT=true
    fi
    log_end_msg $?

    log_action_msg "Set 127.0.0.1 ip for ${hostname}"
    wb_fix_hosts

    log_action_msg "Setting internal Wi-Fi SSID to ${ssid}"
    sed -i "s/^ssid=.*/ssid=${ssid}/" $(readlink -f "/etc/hostapd.conf")
    log_end_msg $?
}

# To run firstboot only once
# https://freedesktop.org/software/systemd/man/machine-id.html
wb_fix_machine_id()
{
    log_action_msg "Generating actual /etc/machine-id"
    systemd-machine-id-setup
}

wb_run_scripts()
{
    local scriptsdir=$1
    if [[ -d $scriptsdir ]]; then
        run-parts -v $scriptsdir
    fi
}

update_fw_env_config()
{
    local config_file="/etc/fw_env.config"
    local device_name="/dev/mmcblk0"
    local offset size offset_hex size_hex

    echo "Reading environment configuration from device tree..."

    if ! offset=$(dtc -I fs -O dtb /proc/device-tree 2>/dev/null | fdtget - /wirenboard env-offset 2>/dev/null); then
        echo "Error: Could not read env-offset from device tree"
        return 1
    fi

    if ! size=$(dtc -I fs -O dtb /proc/device-tree 2>/dev/null | fdtget - /wirenboard env-size 2>/dev/null); then
        echo "Error: Could not read env-size from device tree"
        return 1
    fi

    if [[ ! "$offset" =~ ^[0-9]+$ ]] || [[ ! "$size" =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid offset ($offset) or size ($size) - not numeric"
        return 1
    fi

    offset_hex=$(printf "0x%x" $offset)
    size_hex=$(printf "0x%x" $size)

    cat > "$config_file" << EOF
# Configuration file for fw_(printenv/saveenv) utility.
# Up to two entries are valid, in this case the redundant
# environment sector is assumed present.
#
# XXX this configuration might miss a fifth parameter for the "Number of
# sectors"

# MTD device name   Device offset   Env. size   Flash sector size
$device_name        $offset_hex         $size_hex
EOF
    echo "Successfully updated $config_file"
}

# This function should be called only on first boot of the rootfs
wb_firstboot()
{
    log_action_msg "Preparing rootfs for the first boot"

    update_fw_env_config

    wb_check_data && local data_mounted=1

    [[ ! -d "$WB_DIR" ]] && {
        rm -rf $WB_DIR
        mkdir -p $WB_DIR
    }

    [[ -e "/dev/ttyGSM" ]] && {
		log_action_begin_msg "Fixing GSM modem baudrate"
		wb-gsm init_baud || log_failure_msg "No answer from gsm modem"
		log_end_msg $?
    }

    wb_fix_serial
    wb_fix_macs
    wb_fix_short_sn
    wb_fix_machine_id

    log_action_msg "Generating SSH host keys if necessary"
    for keytype in ecdsa dsa rsa; do
        log_action_begin_msg "  $keytype"
        local keyfile=/etc/ssh_host_${keytype}_key
        [[ -n "$data_mounted" && -e "/mnt/data/$keyfile" ]] &&
        cp "/mnt/data/${keyfile}" "$keyfile" 2>/dev/null &&
        log_action_cont_msg "from shared partition" &&
        log_action_end_msg $? \
        || {
            [[ -f /etc/ssh/ssh_host_${keytype}_key ]] && {
                log_action_cont_msg " already present, keep it"
                log_action_end_msg $? || return $?
            } || {
                yes | ssh-keygen -f /etc/ssh/ssh_host_${keytype}_key -N '' -t ${keytype} >/dev/null
                log_end_msg $? || return $?
            }
        }

    done

    sync

    wb_run_scripts /etc/wb-prepare.d

    if $FIRSTBOOT_NEED_REBOOT; then
        reboot
    fi

    return 0
}

case "$1" in
  firstboot)
    wb_prepare_filesystems
    wb_firstboot
    exit $?
    ;;
  fix_macs)
    wb_fix_macs
    exit 0
    ;;
  fix_short_sn)
    wb_fix_short_sn
    exit 0
    ;;
  fix_hosts)
    wb_fix_hosts
    exit 0
    ;;
  *)
    echo "Usage: $0 {firstboot|fix_macs|fix_short_sn|fix_hosts}" >&2
    exit 3
    ;;
esac
