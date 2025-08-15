#!/bin/bash

set -e

ROOTDEV="${ROOTDEV:-/dev/mmcblk0}"
TMPDIR="${TMPDIR:-/dev/shm}"

# Single or A/B rootfs layout
ROOTFS1_PART=${ROOTDEV}p2
ROOTFS2_PART=${ROOTDEV}p3
SWAP_PART=${ROOTDEV}p5
DATA_PART=${ROOTDEV}p6

# Extended rootfs layout
EXT_ROOTFS_PART=${ROOTDEV}p2
EXT_SWAP_PART=${ROOTDEV}p3
EXT_RESERVED_PART=${ROOTDEV}p4

# appends a command to a trap
#
# - 1st arg:  code to add
# - remaining args:  names of traps to modify
#
trap_add() {
    trap_add_cmd=$1; shift || fatal "${FUNCNAME} usage error"
    for trap_add_name in "$@"; do
        trap -- "$( \
            # helper fn to get existing trap command from output
            # of trap -p
            extract_trap_cmd() { printf '%s\n' "$3"; } \
            # print existing trap command with newline
            eval "extract_trap_cmd $(trap -p "${trap_add_name}")" \
            # print the new trap command
            printf '%s\n' "${trap_add_cmd}" \
        )" "${trap_add_name}" \
            || fatal "unable to add to trap ${trap_add_name}"
    done
}

return_code() {
    return "$1"
}

# This function replaces die() from wb-run-update script.
# It reboots controller in case if script fails during Web-triggered update.
fatal() {
    local retcode=$?
    local msg="$*"

    if [ "$retcode" -eq 0 ]; then
        retcode=1
    fi

    if flag_set from-initramfs; then
        >&2 echo "!!! $msg"
        if flag_set from-webupdate; then
            mqtt_status "ERROR $msg"
        fi
        led_failure
        bash -c 'source /lib/libupdate.sh; buzzer_init; buzzer_on; sleep 1; buzzer_off' || true

        if ! flag_set no-reboot; then
            reboot -f
        fi

        # we may be here if --no-reboot flag is set for debugging
        exit "$retcode"
    else
        return_code "$retcode" || die "$msg"
    fi
}

# takes an array of strings and prints them centered in a box
print_centered_box() {
    local width="${WIDTH:-80}"
    local fill="${FILL:-#}"

    printf "%*s\n" "$width" "" | tr ' ' "$fill"

    for text in "$@"; do
        local text_len=${#text}
        local left_len=$(( (width - text_len) / 2 ))
        local right_len=$(( width - text_len - left_len ))

        printf "%*s%*s\n" "$(( left_len + text_len ))" "$text" "$right_len" ""
    done

    printf "%*s\n" "$width" "" | tr ' ' "$fill"
}

prepare_env() {
    # shellcheck disable=SC2016  # we want to keep $'...' here
    trap_add 'fatal "Error at line $LINENO ($BASH_COMMAND)"' ERR

    # fix mounts in bootlet environment
    if [ ! -e /proc/self ]; then
        mount -t proc proc /proc
    fi

    if [ ! -e /dev/fd ]; then
        ln -s /proc/self/fd /dev/fd
    fi

    if [ ! -e /etc/mtab ]; then
        ln -s /proc/self/mounts /etc/mtab || true
    fi

    if [ ! -e /sys/kernel/config/device-tree ]; then
        mkdir -p /sys/kernel/config
        mount -t configfs configfs /sys/kernel/config
    fi

    WEBUPD_DIR="/mnt/data/.wb-update"

    # FLAGS variable is defined in wb-run-update
    # This is a hack to pass more flags from installation media for debugging
    flags_file="$(dirname "$FIT")/install_update.flags"
    if [ -e "$flags_file" ]; then
        ADDITIONAL_FLAGS=$(cat "$flags_file")
        info "Using flags from $flags_file: $ADDITIONAL_FLAGS"
        FLAGS="$FLAGS $ADDITIONAL_FLAGS "
    fi
    web_flags_file="$(dirname "$FIT")/install_update.web.flags"
    if [ -e "$web_flags_file" ]; then
        ADDITIONAL_FLAGS=$(cat "$web_flags_file")
        info "Using flags from $web_flags_file: $ADDITIONAL_FLAGS"
        FLAGS="$FLAGS $ADDITIONAL_FLAGS "
        if flag_set from-initramfs; then
            info "Removing web flags file $web_flags_file"
            rm "$web_flags_file"
        fi
    fi

    UPDATE_STATUS_FILE="$WEBUPD_DIR/state/update.status"
    UPDATE_LOG_FILE="$WEBUPD_DIR/state/update.log"

    if flag_set from-webupdate; then
        info "Web UI-triggered update detected, forwarding logs and status to files"

        mkdir -p "$(dirname "$UPDATE_STATUS_FILE")"
        mkdir -p "$(dirname "$UPDATE_LOG_FILE")"

        mqtt_status() {
            echo "$*" >> "$UPDATE_LOG_FILE"
            echo "$*" > "$UPDATE_STATUS_FILE"
        }

        rm -rf "$UPDATE_LOG_FILE"
    fi

    # we need to do it before /dev/mmcblk0p6 is unmounted, just in case
    if flag_set external-script && [ -z "$IS_IN_EXTERNAL_SCRIPT" ]; then
        EXTERNAL_SCRIPT="$(dirname "$FIT")/install_update.sh"
        info "--external-script flag is set, looking for external script in $EXTERNAL_SCRIPT"
        if [ -e "$EXTERNAL_SCRIPT" ]; then
            info "Running external script from $EXTERNAL_SCRIPT"

            trap EXIT  # reset all traps, allow external script to set its own
            IS_IN_EXTERNAL_SCRIPT=1
            source "$EXTERNAL_SCRIPT" || fatal "External script failed"
            IS_IN_EXTERNAL_SCRIPT=

            info "Returned from external script, exiting"
            exit 0
        else
            fatal "External script not found"
        fi
    fi

    if ! flag_set no-console-log; then

        TEMP_LOG_FILE="$(mktemp)"

        if flag_set mass-update; then
            FINAL_CONSOLE_LOG_DIR="$(dirname "$FIT")/logs"
            mkdir -p "$FINAL_CONSOLE_LOG_DIR"
            if [[ -w "$FINAL_CONSOLE_LOG_DIR" ]]; then

                move_log_file() {
                    cat "$TEMP_LOG_FILE" >> "$FINAL_CONSOLE_LOG_DIR/wb-console.$SERIAL.log"
                    rm "$TEMP_LOG_FILE"
                }

                exec > >(tee "$TEMP_LOG_FILE") 2>&1
                trap_add "move_log_file; sync; sync" EXIT
                info "Console logging enabled; tempfile $TEMP_LOG_FILE, final file $FINAL_CONSOLE_LOG_DIR/wb-console.%SERIAL%.log will be written on exit"
            fi
        else
            FINAL_CONSOLE_LOG_FILE="$(dirname "$FIT")/wb-console.log"
            if touch "$FINAL_CONSOLE_LOG_FILE" && [[ -w "$FINAL_CONSOLE_LOG_FILE" ]]; then
                exec > >(tee "$TEMP_LOG_FILE") 2>&1
                trap_add "cat '$TEMP_LOG_FILE' >> '$FINAL_CONSOLE_LOG_FILE'; rm '$TEMP_LOG_FILE'; sync; sync" EXIT
                info "Console logging enabled; tempfile $TEMP_LOG_FILE, final file $FINAL_CONSOLE_LOG_FILE will be written on exit"
            fi
        fi

    fi

    type fit_prop_string 2>/dev/null | grep -q 'shell function' || {
        fit_prop_string() {
            fit_prop "$@" | tr -d '\0'
        }
    }

    type mkfs_ext4 2>/dev/null | grep -q 'shell function' || {
        mkfs_ext4() {
            local part=$1
            local label=$2

            yes | mkfs.ext4 -L "$label" -E stride=2,stripe-width=1024 -b 4096 "$part"
        }
    }

    #umount "$ROOTFS1_PART" >/dev/null 2>&1 || true
    umount "$ROOTFS2_PART" >/dev/null 2>&1 || true

    if ! flag_set from-webupdate && ! flag_set from-emmc-factoryreset; then
        umount "$DATA_PART" >/dev/null 2>&1 || true
    fi
}

ensure_tools() {
    if [ -z "$TOOLPATH" ]; then
        TOOLPATH=$(mktemp -d)
        export TOOLPATH
        mkdir -p "$TOOLPATH/proc" "$TOOLPATH/dev" "$TOOLPATH/etc" "$TOOLPATH/tmp"
        mount -t proc proc "$TOOLPATH/proc"
        ln -s /proc/self/mounts "$TOOLPATH/etc/mtab"
        mount --bind /dev "$TOOLPATH/dev"

        info "Temp toolpath: $TOOLPATH"

        fit_blob_data rootfs | tar xz -C "$TOOLPATH" ./var/lib/wb-image-update/deps.tar.gz
        tar xzf "$TOOLPATH/var/lib/wb-image-update/deps.tar.gz" -C "$TOOLPATH"
    fi
}

run_tool() {
    ensure_tools
    chroot "$TOOLPATH" "$@"
}

is_assoc_array() {
    [[ "$(declare -p "$1" 2>/dev/null)" =~ "declare -A" ]]
}

push_umount() {
    if ! is_assoc_array SAVED_MOUNTPOINTS; then
        declare -g -A SAVED_MOUNTPOINTS
    fi

    local part=$1
    local mountpoint
    mountpoint=$(mount | grep "$part" | awk '{print $3}')

    for mountpoint in $(mount | grep "$part" | awk '{print $3}'); do
        info "Unmounting $mountpoint and saving its mountpoint"
        umount "$mountpoint"
        SAVED_MOUNTPOINTS["$mountpoint"]="$part"
    done
}

pop_mounts() {
    if ! is_assoc_array SAVED_MOUNTPOINTS; then
        info "No old mountpoints to restore"
        return
    fi

    for mountpoint in "${!SAVED_MOUNTPOINTS[@]}"; do
        local part="${SAVED_MOUNTPOINTS[$mountpoint]}"
        info "Restoring mount of $part to $mountpoint"
        mount "$part" "$mountpoint"
    done

    unset SAVED_MOUNTPOINTS
}

reload_parttable() {
    push_umount "$ROOTFS1_PART"
    push_umount "$ROOTFS2_PART"
    push_umount "$DATA_PART"

    blockdev --rereadpt "$ROOTDEV"; RC=$?

    pop_mounts || true

    return $RC
}

disk_layout_is_ab() {
    [ "$(blockdev --getsz "$ROOTFS1_PART")" -eq "$(blockdev --getsz "$ROOTFS2_PART")" ]
}

disk_layout_is_extended() {
    [ ! -e "$DATA_PART" ]
}

sfdisk_set_size() {
    sed "s#^\\($1.*size=\\s\\+\\)[0-9]\\+\\(.*\\)#\\1 $2\\2#"
}

sfdisk_set_start() {
    sed "s#^\\($1.*start=\\s\\+\\)[0-9]\\+\\(.*\\)#\\1 $2\\2#"
}

sfdisk_set_type() {
    sed "s#^\\($1.*type=\\)[0-9]\\+#\\1$2#"
}

sfdisk_rm_partition() {
    sed "\#$1#d"
}

run_e2fsck() {
    local part=$1
    local E2FSCK_RC
    local tmpdir
    tmpdir=$(mktemp -d)

    # resize2fs wants last mount time to be less than last check time
    # (see https://github.com/tytso/e2fsprogs/blob/67f2b54667e65cf5a478fcea8b85722be9ee6e8d/resize/main.c#L442)
    # target system could have incorrect time => e2fsck could leave fs last_check timestamp untouched
    # (see https://github.com/tytso/e2fsprogs/blob/e76886f76dfca6b9228902cff028b3b7b1ac3131/e2fsck/e2fsck.c#L44)

    # so we need to renew partition's mount and check timestamps manually

    info "Mounting partition before calling e2fsck to renew mount time"
    mount "$part" "$tmpdir"
    umount "$tmpdir"; rmdir "$tmpdir"; sync

    info "Checking and repairing filesystem on $part"
    run_tool e2fsck -f -p "$part"; E2FSCK_RC=$?

    # e2fsck returns 1 and 2 if some errors were fixed, it's OK for us
    if [ "$E2FSCK_RC" -gt 2 ]; then
        info "Filesystem check failed, can't proceed with resizing"
        return 1
    fi

    # force update last_check ts
    run_tool tune2fs -T now $part

    if flag_set print-dumpe2fs; then
        info "Filesystem info after e2fsck on $part"
        dumpe2fs_output=$(run_tool dumpe2fs "$part")
        info "$dumpe2fs_output"
    fi
}

restore_mbr() {
    local mbr_backup=$1
    dd if="$mbr_backup" of="$ROOTDEV" oflag=direct conv=notrunc || true
    sync
    reload_parttable
}

ensure_extended_rootfs_parttable() {
    if disk_layout_is_extended; then
        info "Partition table seems to be changed already, continue"
        return 0
    fi

    info "Start repartition for extended-rootfs"

    run_e2fsck "$EXT_ROOTFS_PART"

    info "Backing up old MBR (and partition table)"
    local mbr_backup
    mbr_backup=$(mktemp)
    dd if="$ROOTDEV" of="$mbr_backup" bs=512 count=1 || {
        info "Failed to save MBR backup"
        return 1
    }

    # Extended rootfs layout (8Gb):
    #
    # /dev/mmcblk0p1 : start=        2048, size=       32768, type=53  # 16M
    # /dev/mmcblk0p2 : start=       34816, size=    13137920, type=83  # 6,3G
    # /dev/mmcblk0p3 : start=    13172736, size=     1048576, type=82  # 512M
    # /dev/mmcblk0p4 : start=    14221312, size=     1048576, type=83  # 512M
    #
    # Extended rootfs layout (16Gb):
    #
    # /dev/mmcblk0p1 : start=        2048, size=       32768, type=53  # 16M
    # /dev/mmcblk0p2 : start=       34816, size=    29915136, type=83  # 14.3G
    # /dev/mmcblk0p3 : start=    29949952, size=     1048576, type=82  # 512M
    # /dev/mmcblk0p4 : start=    30998528, size=     1048576, type=83  # 512M
    #
    # Extended rootfs layout (64Gb):
    #
    # /dev/mmcblk0p1 : start=        2048, size=       32768, type=53  # 16M
    # /dev/mmcblk0p2 : start=       34816, size=   130578432, type=83  # 62.3G
    # /dev/mmcblk0p3 : start=   130613248, size=     1048576, type=82  # 512M
    # /dev/mmcblk0p4 : start=   131661824, size=     1048576, type=83  # 512M
    #

    TEMP_DUMP="$(mktemp)"
    info "New disk dump will be saved in $TEMP_DUMP"

    info "Creating a new parition table"

    ROOTFS_START_BLOCKS=34816
    SWAP_SIZE_BLOCKS=1048576
    RESERVED_SIZE_BLOCKS=1048576

    local emmc_size=$(blockdev --getsize64 $ROOTDEV)
    case "$((emmc_size / 1024 / 1024 / 1024))" in
        7)
            info "8G emmc"
            RESERVED_START_BLOCKS=14221312
            ;;
        14)
            info "16G emmc"
            RESERVED_START_BLOCKS=30998528
            ;;
        58)
            info "64G emmc"
            RESERVED_START_BLOCKS=131661824
            ;;
        *)
            info "Unknown emmc size: $emmc_size bytes"
            return 1
            ;;
    esac

    SWAP_START_BLOCKS=$(( RESERVED_START_BLOCKS - SWAP_SIZE_BLOCKS ))
    ROOTFS_SIZE_BLOCKS=$(( SWAP_START_BLOCKS - ROOTFS_START_BLOCKS ))

    info "Umount partitions"
    umount "$ROOTFS1_PART" >/dev/null 2>&1 || true
    umount "$ROOTFS2_PART" >/dev/null 2>&1 || true
    umount "$DATA_PART" >/dev/null 2>&1 || true

    sfdisk --dump "$ROOTDEV" | \
        sfdisk_set_size  "$EXT_ROOTFS_PART" "$ROOTFS_SIZE_BLOCKS" | \
        sfdisk_rm_partition "$SWAP_PART" | \
        sfdisk_rm_partition "$DATA_PART" | \
        sfdisk_set_start "$EXT_SWAP_PART" "$SWAP_START_BLOCKS" | \
        sfdisk_set_size "$EXT_SWAP_PART" "$SWAP_SIZE_BLOCKS" | \
        sfdisk_set_type "$EXT_SWAP_PART" 82 | \
        sfdisk_set_start "$EXT_RESERVED_PART" "$RESERVED_START_BLOCKS" | \
        sfdisk_set_size "$EXT_RESERVED_PART" "$RESERVED_SIZE_BLOCKS" | \
        sfdisk_set_type "$EXT_RESERVED_PART" 83 | \
        tee "$TEMP_DUMP" | \
        sfdisk -f "$ROOTDEV" --no-reread >/dev/null || {

        info "New parttable creation failed, restoring saved MBR backup"
        cat "$TEMP_DUMP"
        restore_mbr "$mbr_backup"
        return 1
    }

    cat "$TEMP_DUMP"
    sync
    reload_parttable

    if [ "$(blockdev --getsz "$EXT_ROOTFS_PART")" != "$ROOTFS_SIZE_BLOCKS" ]; then
        info "New parttable is not applied, restoring saved MBR backup and exit"
        restore_mbr "$mbr_backup"
        fatal "Failed to apply a new partition table"
    fi

    info "Creating filesystem on rootfs partition"
    mkfs_ext4 "$EXT_ROOTFS_PART" "rootfs" || {
        info "Creating new filesystem on rootfs partition failed!"
        info "Restoring saved MBR backup and exit"
        restore_mbr "$mbr_backup"
        fatal "Failed to create filesystem on new rootfs, exiting"
    }

    info "Creating filesystem on swap partition"
    mkswap "$EXT_SWAP_PART" || {
        info "Creating new filesystem on swap partition failed!"
        info "Restoring saved MBR backup and exit"
        restore_mbr "$mbr_backup"
        fatal "Failed to create filesystem on new swap, exiting"
    }

    info "Creating filesystem on reserved partition"
    mkfs_ext4 "$EXT_RESERVED_PART" "reserved" || {
        info "Creating new filesystem on reserved partition failed!"
        info "Restoring saved MBR backup and exit"
        restore_mbr "$mbr_backup"
        fatal "Failed to create filesystem on new reserved, exiting"
    }
    mmc writeprotect user set temp $RESERVED_START_BLOCKS $RESERVED_SIZE_BLOCKS $ROOTDEV

    info "Repartition is done!"
}

ensure_enlarged_rootfs_parttable() {
    if ! disk_layout_is_ab; then
        info "Partition table seems to be changed already, continue"
        return 0
    fi

    info "Enlarging first rootfs partition"

    run_e2fsck "$ROOTFS1_PART"

    info "Backing up old MBR (and partition table)"
    local mbr_backup
    mbr_backup=$(mktemp)
    dd if="$ROOTDEV" of="$mbr_backup" bs=512 count=1 || {
        info "Failed to save MBR backup"
        return 1
    }

    # Classic layout:
    #
    # label: dos
    # label-id: 0x3f9de3f0
    # device: /dev/mmcblk0
    # unit: sectors
    # sector-size: 512
    #
    # /dev/mmcblk0p1 : start=        2048, size=       32768, type=53
    # /dev/mmcblk0p2 : start=       34816, size=     2097152, type=83
    # /dev/mmcblk0p3 : start=     2131968, size=     2097152, type=83
    # /dev/mmcblk0p4 : start=     4229120, size=   117913600, type=5
    # /dev/mmcblk0p5 : start=     4231168, size=      524288, type=82
    # /dev/mmcblk0p6 : start=     4757504, size=   117385216, type=83  # differs between models
    #
    # New layout with mmcblk0p3 size == 4 blocks:
    #
    # ...  # unchanged
    # /dev/mmcblk0p2 : start=       34816, size=     4194300, type=83
    # /dev/mmcblk0p3 : start=     4229116, size=           4, type=83
    # /dev/mmcblk0p4 : start=     4229120, size=   117913600, type=5
    # ...  # unchanged
    #
    # All this sfdisk magic is here to keep label-id and other partitions safe and sound

    info "Creating a new parition table"
    ROOTFS_START_BLOCKS=34816
    ROOTFS_SIZE_BLOCKS=4194300

    TEMP_DUMP="$(mktemp)"
    info "New disk dump will be saved in $TEMP_DUMP"

    sfdisk --dump "$ROOTDEV" | \
        sfdisk_set_size  "$ROOTFS1_PART" "$ROOTFS_SIZE_BLOCKS" | \
        sfdisk_set_start "$ROOTFS2_PART" "$((ROOTFS_START_BLOCKS + ROOTFS_SIZE_BLOCKS))" | \
        sfdisk_set_size  "$ROOTFS2_PART" 4 | \
        tee "$TEMP_DUMP" | \
        sfdisk -f "$ROOTDEV" --no-reread >/dev/null || {

        info "New parttable creation failed, restoring saved MBR backup"
        restore_mbr "$mbr_backup"
        return 1
    }

    sync
    reload_parttable

    if [ "$(blockdev --getsz "$ROOTFS1_PART")" != "$ROOTFS_SIZE_BLOCKS" ]; then
        info "New parttable is not applied, restoring saved MBR backup and exit"
        restore_mbr "$mbr_backup"
        fatal "Failed to apply a new partition table"
    fi

    info "Expanding filesystem on this partition"
    local e2fs_undofile
    e2fs_undofile=$(mktemp)
    run_tool e2fsck -y "$ROOTFS1_PART"
    run_tool resize2fs -z "$e2fs_undofile" "$ROOTFS1_PART" || {
        info "Filesystem expantion failed, restoring everything"
        run_tool e2undo "$e2fs_undofile" "$ROOTFS1_PART" || true
        restore_mbr "$mbr_backup"
        return 1
    }

    info "Repartition is done!"
}

ensure_ab_rootfs_parttable() {
    if disk_layout_is_ab; then
        info "Partition table seems to be A/B, continue"
        return 0
    fi

    info "Restoring A/B partition table"

    cleanup_rootfs "$ROOTFS1_PART"

    run_e2fsck "$ROOTFS1_PART" || {
        info "Filesystem check failed, can't proceed with restoring A/B partition table"
        return 1
    }

    info "Shrinking filesystem on $ROOTFS1_PART"
    local e2fs_undofile
    e2fs_undofile=$(mktemp)
    run_tool resize2fs -z "$e2fs_undofile" "$ROOTFS1_PART" 262144 || {
        info "Filesystem expantion failed, restoring everything"
        run_tool e2undo "$e2fs_undofile" "$ROOTFS1_PART" || true
        sync
        return 1
    }

    info "Backing up old MBR (and partition table)"
    local mbr_backup
    mbr_backup=$(mktemp)
    dd if="$ROOTDEV" of="$mbr_backup" bs=512 count=1 || {
        info "Failed to save MBR backup"
        return 1
    }

    # Classic layout:
    #
    # label: dos
    # label-id: 0x3f9de3f0
    # device: /dev/mmcblk0
    # unit: sectors
    # sector-size: 512
    #
    # /dev/mmcblk0p1 : start=        2048, size=       32768, type=53
    # /dev/mmcblk0p2 : start=       34816, size=     2097152, type=83
    # /dev/mmcblk0p3 : start=     2131968, size=     2097152, type=83
    # /dev/mmcblk0p4 : start=     4229120, size=   117913600, type=5
    # /dev/mmcblk0p5 : start=     4231168, size=      524288, type=82
    # /dev/mmcblk0p6 : start=     4757504, size=   117385216, type=83  # differs between models
    #
    # All this sfdisk magic is here to keep label-id and other partitions safe and sound

    info "Creating a new parition table"
    ROOTFS_START_BLOCKS=34816
    ROOTFS_SIZE_BLOCKS=2097152

    TEMP_DUMP="$(mktemp)"
    info "New disk dump will be saved in $TEMP_DUMP"

    sfdisk --dump "$ROOTDEV" | \
        sfdisk_set_size  "$ROOTFS1_PART" "$ROOTFS_SIZE_BLOCKS" | \
        sfdisk_set_start "$ROOTFS2_PART" "$((ROOTFS_START_BLOCKS + ROOTFS_SIZE_BLOCKS))" | \
        sfdisk_set_size  "$ROOTFS2_PART" "$ROOTFS_SIZE_BLOCKS" | \
        tee "$TEMP_DUMP" | \
        sfdisk -f "$ROOTDEV" --no-reread >/dev/null || {

        info "New parttable creation failed, restoring saved MBR backup"
        restore_mbr "$mbr_backup"
        return 1
    }

    sync
    reload_parttable

    if [ "$(blockdev --getsz "$ROOTFS1_PART")" != "$ROOTFS_SIZE_BLOCKS" ]; then
        info "New parttable is not applied, restoring saved MBR backup and exit"
        restore_mbr "$mbr_backup"
        fatal "Failed to apply a new partition table"
    fi

    info "Creating filesystem on second partition"
    mkfs_ext4 "$ROOTFS2_PART" "rootfs" || {
        info "Creating new filesystem on second partition failed!"
        info "Restoring saved MBR backup and exit"
        restore_mbr "$mbr_backup"
        fatal "Failed to create filesystem on new rootfs, exiting"
    }

    info "Repartition is done!"
}

cleanup_rootfs() {
    local ROOT_PART="$1"
    local mountpoint
    mountpoint="$(mktemp -d)"

    mount -t ext4 "$ROOT_PART" "$mountpoint" >/dev/null 2>&1 || fatal "Unable to mount root filesystem"

    info "Cleaning up $ROOT_PART"
    rm -rf /tmp/empty && mkdir /tmp/empty
    if which rsync >/dev/null; then
        info "Cleaning up using rsync"
        rsync -a --delete --exclude="/mnt/data/.wb-restore/" --exclude="/mnt/data/.wb-update/" /tmp/empty/ "$mountpoint" || fatal "Failed to cleanup rootfs"
    else
        info "Can't find rsync, cleaning up using rm -rf (may be slower)"
        rm -rf "$mountpoint"/..?* "$mountpoint"/.[!.]* "${mountpoint:?}"/* || fatal "Failed to cleanup rootfs"
    fi

    umount "$mountpoint" || true
}

ensure_uboot_ready_for_webupd() {
    local version
    version=$(awk '{ print $2 }' /proc/device-tree/chosen/u-boot-version | sed 's/-g[0-9a-f]\+$//')
    if dpkg --compare-versions "$version" lt "2021.10-wb1.6.0~~"; then
        info "Flashed U-boot version is too old, updating it before reboot"
        u-boot-install-wb -f || fatal "Failed to update U-boot"
    fi
}

check_compatible() {
    local fit_compat
    fit_compat=$(fit_prop_string / compatible)
    [[ -z "$fit_compat" || "$fit_compat" == "unknown" ]] && return 0
    for compat in $(tr < /proc/device-tree/compatible  '\000' '\n'); do
        [[ "$fit_compat" == "$compat" ]] && return 0
    done
    return 1
}

select_new_partition() {
    info "Getting mmcpart from U-Boot environment"
    PART=$(fw_printenv mmcpart | sed 's/.*=//') || PART=""

    case "$PART" in
        2)
            PART=3
            PREVIOUS_PART=2
            ;;
        3)
            PART=2
            PREVIOUS_PART=3
            ;;
        *)
            if flag_set from-initramfs; then
                info "Update is started from initramfs and unable to determine active rootfs partition, will overwrite rootfs0"
                PART=2
                PREVIOUS_PART=3
            else
                fatal "Unable to determine second rootfs partition (current is '$PART')"
            fi
            ;;
    esac
}

extend_tmpfs_size(){
    info "Extend tmpfs size to whole RAM"
    MEMSIZE_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    MEMSIZE_MB=$((MEMSIZE_KB / 1024))

    info "Remount tmpfs in /tmp with size=${MEMSIZE_MB}M"
    mount -o remount,size=${MEMSIZE_MB}M /tmp
}

mount_data_dir() {
    local mnt
    mnt=$(mktemp -d)
    if disk_layout_is_extended; then
        mount "$ROOTFS1_PART" "$mnt" || fatal "Unable to mount root partition"
        echo "$mnt /mnt/data/"
    else
        mount "$DATA_PART" "$mnt" || fatal "Unable to mount data partition"
        echo "$mnt /"
    fi
}

maybe_update_current_factory_tmpfs_size_fix() {
    info "Maybe update factoryreset.fit to fix tmpfs size issue at 512M RAM (with emmc update)"

    MEMSIZE_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    MEMSIZE_MB=$((MEMSIZE_KB / 1024))

    if ((MEMSIZE_MB<1024)); then

        local mnt prefix factory_fit
        set -- $(mount_data_dir) || fatal "Unable to mount data partition"
        mnt=$1
        prefix=$2
        factory_fit="$mnt$prefix.wb-restore/factoryreset.fit"

        if ! FIT="$factory_fit" fw_compatible repartition-ramsize-fix; then
            info "Replace factoryreset.fit with current fit to fix rootfs extending issue at 512M RAM"
            copy_this_fit_to_factory
        else
            info "Factoryreset.fit already includes a fix for the 512MB RAM repartition issue (repartition-ramsize-fix compatibility)"
        fi

        umount "$mnt" || true
        sync
    fi
}

maybe_repartition() {
    if flag_set restore-ab-rootfs ; then
        info "Restoring A/B scheme as requested"
        if ! ensure_ab_rootfs_parttable; then
            fatal "Failed to restore A/B scheme"
        fi
        info "A/B scheme restored!"
        return
    fi

    if flag_set extend-rootfs && ! flag_set from-webupdate && ! flag_set from-emmc-factoryreset; then
        info "Extending rootfs as requested"
        if ! ensure_extended_rootfs_parttable; then
            fatal "Failed to extend rootfs"
        fi
        info "rootfs extended!"
        return
    fi

    if ensure_enlarged_rootfs_parttable; then
        info "rootfs enlarged!"
    else
        info "Repartition failed, continuing without it"
    fi
}

get_update_debian_version() {
    fit_prop_string / release-target | sed 's/wb[[:digit:]]\+\///'
}

get_installed_debian_version() {
    actual_rootfs=${ROOTDEV}p${PREVIOUS_PART}
    local MNT
    MNT=$(mktemp -d)

    if flag_set from-initramfs ; then
        if [[ -e "$actual_rootfs" ]]; then
            info "Temporarily mount actual rootfs $actual_rootfs to check previous OS release"
            if mount -t ext4 "$actual_rootfs" "$MNT" >/dev/null 2>&1 ; then
                sync
                source "$MNT/etc/os-release"
                echo "$VERSION_CODENAME"
                umount -f "$actual_rootfs" >/dev/null 2>&1 || true
            else
                info "Failed to mount rootfs from $actual_rootfs, skipping release check"
                echo "unknown"
            fi
        fi
    else
        source "/etc/os-release"
        echo "$VERSION_CODENAME"
    fi
}

ensure_no_downgrade() {
    actual=$(get_installed_debian_version)
    upcoming=$(get_update_debian_version)

    info "Debian: $actual -> $upcoming"
    if [ "$actual" = "bullseye" ] && [ "$upcoming" = "stretch" ]; then
        if ! flag_set factoryreset; then
            message=(
                ""
                "ROLLBACK FROM $actual TO $upcoming REQUESTED"
                ""
                "Due to major Debian release changes,"
                "this operation is allowed only via FACTORYRESET."
                ""
                "Rename .fit file to \"wbX_update_FACTORYRESET.fit\" ->"
                "put renamed file to usb-drive ->"
                "ensure, there is only one .fit file on usb-drive ->"
                "insert usb-drive to controller and reboot ->"
                "follow further factoryreset instructions."
                ""
            )

            print_centered_box "${message[@]}"
            fatal "Rollback from $actual to $upcoming is not allowed"
        fi
    fi
}

mount_rootfs() {
    local ROOT_PART=$1
    local MNT=$2
    info "Mounting $ROOT_PART at $MNT"
    mount -t ext4 "$ROOT_PART" "$MNT" >/dev/null 2>&1 || fatal "Unable to mount root filesystem"

    trap_add "info 'Unmounting rootfs'; umount -f $MNT >/dev/null 2>&1 || true ; sync" EXIT
}

extract_rootfs() {
    local MNT=$1

    info "Extracting files to new rootfs"
    pushd "$MNT"
    blob_size=$(fit_blob_size rootfs)
    (
        echo 0
        fit_blob_data rootfs | pv -n -s "$blob_size" | tar xzp || fatal "Failed to extract rootfs"
    ) 2>&1 | mqtt_progress "$x"
    popd
}

recover_certificates() {
    HIDDENFS_PART=${ROOTDEV}p1
    HIDDENFS_OFFSET=$((8192*512))  # 8192 blocks of 512 bytes
    DEVCERT_NAME="device.crt.pem"
    INTERM_NAME="intermediate.crt.pem"
    ROOTFS_CERT_PATH="/etc/ssl/certs/device_bundle.crt.pem"

    local ROOTFS_MNT=$1

    local HIDDENFS_MNT
    HIDDENFS_MNT=$(mktemp -d)

    info "Recovering device certificates"
    # make loop device
    LO_DEVICE=$(losetup -f)
    losetup -r -o "$HIDDENFS_OFFSET" "$LO_DEVICE" "$HIDDENFS_PART" ||
        fatal "Failed to add loopback device"

    if mount "$LO_DEVICE" "$HIDDENFS_MNT" >/dev/null 2>&1; then
        cat "$HIDDENFS_MNT/$INTERM_NAME" "$HIDDENFS_MNT/$DEVCERT_NAME" > "$ROOTFS_MNT/$ROOTFS_CERT_PATH" ||
            info "WARNING: Failed to copy device certificate bundle into new rootfs. Please report it to our support service"
        umount "$HIDDENFS_MNT"
        sync
    else
        info "WARNING: Failed to find certificates of device. Please report it to our support service"
    fi
}

mount_proc_sys_dev() {
    local ROOTFS_MNT=$1

    info "Mount /dev, /proc and /sys to rootfs $ROOTFS_MNT"
    mount -o bind /dev "$ROOTFS_MNT/dev"
    mount -o bind /proc "$ROOTFS_MNT/proc"
    mount -o bind /sys "$ROOTFS_MNT/sys"
    mount -o bind /sys/kernel/config "$ROOTFS_MNT/sys/kernel/config"
}

umount_proc_sys_dev() {
    local ROOTFS_MNT=$1

    info "Unmounting /dev, /proc and /sys from rootfs $ROOTFS_MNT"
    umount "$ROOTFS_MNT/dev"
    umount "$ROOTFS_MNT/proc"
    umount "$ROOTFS_MNT/sys/kernel/config"
    umount "$ROOTFS_MNT/sys"
}

run_postinst() {
    local ROOTFS_MNT=$1

    mount_proc_sys_dev "$ROOTFS_MNT"

    POSTINST_DIR=${2:-"$ROOTFS_MNT/usr/lib/wb-image-update/postinst/"}
    if [[ -d "$POSTINST_DIR" ]]; then
        info "Running post-install scripts"

        POSTINST_FILES="$(find "$POSTINST_DIR" -maxdepth 1 -type f | sort)"
        for file in $POSTINST_FILES; do
            info "> Processing $file"
            FIT="$FIT" "$file" "$ROOTFS_MNT" "$FLAGS" || true
        done
    fi

    umount_proc_sys_dev "$ROOTFS_MNT"
}

copy_this_fit_to_factory() {
    info "Copying $FIT to factory default location as requested"

    local mnt prefix factory_fit
    set -- $(mount_data_dir) || fatal "Unable to mount data partition"
    mnt=$1
    prefix=$2
    factory_fit="$mnt$prefix.wb-restore/factoryreset.fit"

    if FIT="$factory_fit" fw_compatible "fit-immutable-support"; then
        info "Saving immutability state of $factory_fit"
        local was_immutable=$(lsattr -l $factory_fit | grep "Immutable" || true)
        chattr -i $factory_fit
        cp "$FIT" "$factory_fit"
        [[ -n "$was_immutable" ]] && chattr +i $factory_fit
    else  # no chattr / lsattr in factory fit
        cp "$FIT" "$factory_fit"
    fi
    umount "$mnt" || true
    sync
}

update_current_factory_fit_if_not_compatible() {
    local fit_compat_features=$1
    local mnt prefix factory_fit
    set -- $(mount_data_dir) || fatal "Unable to mount data partition"
    mnt=$1
    prefix=$2

    # check if current fit supports +single-rootfs feature
    wb_restore_dir="$mnt$prefix.wb-restore"
    factory_fit="$wb_restore_dir/factoryreset.fit"
    original_factory_fit="$wb_restore_dir/factoryreset.original.fit"

    info "Checking, $factory_fit supports features: $fit_compat_features"
    if [[ ! -e "$factory_fit" ]]; then
        info "No factory FIT found, storing this update as factory FIT to use as bootlet"
        mkdir -p "$wb_restore_dir"
        cp "$FIT" "$factory_fit"
        umount "$mnt" || true
        sync
        return
    fi

    local features_required
    local features_unsupported
    IFS=' ' read -ra features_required <<< "$fit_compat_features"
    for feature in "${features_required[@]}"; do
        FIT="$factory_fit" fw_compatible $feature || features_unsupported="$features_unsupported $feature"
        fw_compatible $feature || die "$feature is required, but not supported in $FIT! Choose another FIT"
    done
    if [[ -n "$features_unsupported" ]]; then
        info "Storing this update as factory FIT to use as bootlet (supports $fit_compat_features)"
        info "Old factory FIT will be kept as factoryreset.original.fit and will still be used to restore firmware"

        cp "$factory_fit" "$original_factory_fit"
        sync
        copy_this_fit_to_factory
    else
        info "Current factory FIT supports: $fit_compat_features, keeping it"
    fi

    umount "$mnt" || true
    sync
}

maybe_trigger_original_factory_fit_to_restore_ab() {
    local mnt prefix original_factory_fit
    set -- $(mount_data_dir) || fatal "Unable to mount data partition"
    mnt=$1
    prefix=$2

    # check if current fit supports +single-rootfs feature
    original_factory_fit="$mnt$prefix.wb-restore/factoryreset.original.fit"

    if [ -e "$original_factory_fit" ] && (! FIT=$original_factory_fit fw_compatible "single-rootfs"); then
        info "Original factory FIT exists and not support single-rootfs, ensuring A/B rootfs scheme and use it to restore firmware"
        ensure_ab_rootfs_parttable || fatal "Failed to restore A/B rootfs scheme"

        info "Decoding current flags from '$FLAGS'"
        read -r -a FLAGS_ARRAY <<< "$FLAGS" || fatal "Failed to decode flags"

        info "Restoring original firmware from $original_factory_fit, flags ${FLAGS_ARRAY[*]}"
        wb-run-update "${FLAGS_ARRAY[@]}" --no-remove --no-confirm --original-factory-fit "$original_factory_fit" || fatal "Failed to restore firmware from original FIT"

        info "Original factory FIT restored, rebooting system"
        trap_add maybe_reboot EXIT
        exit 0
    fi

    umount "$mnt" || true
    sync
}

maybe_reboot() {
    if ! flag_set no-reboot; then
        info "Reboot system"
        mqtt_status REBOOT
        sync

        if flag_set from-initramfs; then
            reboot -f
        else
            reboot
        fi
    else
        info "Reboot is suppressed by flag --no-reboot, just exiting"
    fi
    exit 0
}

update_after_reboot() {
    ensure_uboot_ready_for_webupd

    info "Watch logs in the debug console, or in $UPDATE_LOG_FILE"
    info "Rebooting system to install update"
    info "Waiting for Wiren Board to boot again..."

    mkdir -p "$WEBUPD_DIR"
    mkdir -p "$(dirname "$UPDATE_STATUS_FILE")"
    mkdir -p "$(dirname "$UPDATE_LOG_FILE")"

    TARGET_UPDATE_FILE="$WEBUPD_DIR/webupd.fit"

    if [[ "$TARGET_UPDATE_FILE" -ef "$FIT" ]]; then
        if flag_set no-remove; then
            # FIXME: pass --no-remove to bootlet via flags file
            fatal "Flag --no-remove is ignored for $FIT, it is after-reboot FIT location"
        fi
    else
        if flag_set no-remove; then
            info "Flag --no-remove is set, keeping $FIT"
            cp "$FIT" "$TARGET_UPDATE_FILE"
        else
            mv "$FIT" "$TARGET_UPDATE_FILE"
        fi
    fi

    # write error note by default in the update status file,
    # it will be overwritten if update script is started properly after reboot
    echo "ERROR Nothing happened after reboot, maybe U-boot is outdated?" > "$UPDATE_STATUS_FILE"

    fw_setenv wb_webupd 1

    trap_add maybe_reboot EXIT
    exit 0
}

fw_compatible() {
    local feature="$1"
    local fw_compat
    fw_compat=$(fit_prop_string / firmware-compatible)

    case "$fw_compat" in
        *"+$feature "*) return 0 ;;
        *) return 1 ;;
    esac
}

play_note() {
    local FREQ=$1
    local NOTE_LENGTH=$2
    local SILENCE_LENGTH=$3
    local VOLUME=100

    local PERIOD=$(( 1000000000 / $FREQ ))
    local DUTY_CYCLE=$(( (VOLUME / 100) * $PERIOD / 2 ))

    echo $PWM_BUZZER > /sys/class/pwm/pwmchip0/export 2>/dev/null || true

    local r1=1
    local r2=1
    while [ $r1 -ne 0 ] || [ $r2 -ne 0 ]; do
        echo $DUTY_CYCLE > /sys/class/pwm/pwmchip0/pwm${PWM_BUZZER}/duty_cycle 2>/dev/null || true
        r1=$?
        echo $PERIOD > /sys/class/pwm/pwmchip0/pwm${PWM_BUZZER}/period 2>/dev/null || true
        r2=$?
    done
    buzzer_on
    sleep $NOTE_LENGTH
    buzzer_off
    sleep $SILENCE_LENGTH
}

beep_success() {
    source /lib/libupdate.sh || true

    play_note 2793 0.1 0.02 # F7
    play_note 3135 0.1 0.02 # G7
    play_note 3520 0.3 0 # A7
}

populate_serial_and_fit_ver() {
    local ROOTFS_MNT=$1

    info "Populating serial number and fit version"
    mount_proc_sys_dev "$ROOTFS_MNT"

    SERIAL=$(chroot "$ROOTFS_MNT" /usr/bin/wb-gen-serial -s)
    FIT_VERSION=$(cat "$ROOTFS_MNT/usr/lib/wb-release" | grep TARGET)
    FIT_VERSION="$FIT_VERSION $(cat "$ROOTFS_MNT/usr/lib/wb-release" | grep SUITE)"
    FIT_VERSION="$FIT_VERSION $(cat "$ROOTFS_MNT/etc/wb-fw-version")"
    if [ -f "$ROOTFS_MNT/etc/wb-fw-custom" ]; then
        FIT_VERSION="$FIT_VERSION $(cat "$ROOTFS_MNT/etc/wb-fw-custom")"
    fi

    umount_proc_sys_dev "$ROOTFS_MNT"
}

log_mass_update() {
    local LOGS_DIR="$(dirname "$FIT")/logs"

    mkdir -p "$LOGS_DIR"
    if flag_set factoryreset; then
        echo "Unit $SERIAL factoryreset with fit $FIT_VERSION" >> "$LOGS_DIR/wb-mass-update.log"
    else
        echo "Unit $SERIAL updated with fit $FIT_VERSION" >> "$LOGS_DIR/wb-mass-update.log"
    fi
}

fw_has_proper_dtb() {
    local EMMC=${EMMC:-/dev/mmcblk0}
    local TMPFILE=$(mktemp)
    # creating empty DTB to apply overlay to
    echo "/dts-v1/; / { wirenboard {}; };" | dtc -I dts -O dtb -o "$TMPFILE"
    dtb_name=$(dd "if=$EMMC" bs=512 skip=2016 count=32 | fdtoverlay -i "$TMPFILE" -o - - | fdtget -t s - /wirenboard factory-fdt)
    rm -f $TMPFILE

    fit_blob_data rootfs | tar tz | grep -q -m1 -F "$dtb_name"
}

check_firmware_compatible() {
    if flag_set force-fw-compatible; then
        info "Firmware compatibility check skipped"
        return
    fi

    if ! fw_has_proper_dtb; then
        info "This firmware is too old for this device, please use newer one from https://fw-releases.wirenboard.com/"
        fatal "Firmware is not compatible with this device, no proper DTB found"
    fi

    info "Firmware seems to be compatible with this controller"
}

maybe_factory_reset() {
    if flag_set from-initramfs; then
        info "Wiping data partition (factory reset)"

        mkdir -p /mnt
        mkdir -p /mnt/data
        if [[ -b "$DATA_PART" ]]; then
            mount -t auto $DATA_PART /mnt/data 2>/dev/null || true
        else
            mkdir -p /mnt/rootfs
            mount -t auto "${ROOT_PART}" /mnt/rootfs || true
            mount --bind /mnt/rootfs/mnt/data /mnt/data || true
        fi

        rm -rf /tmp/empty && mkdir /tmp/empty
        rsync -a --delete --exclude="/.wb-restore/" --exclude="/.wb-update/" /tmp/empty/ /mnt/data/

        FACTORY_FIT_DIR="/mnt/data/.wb-restore"
        FACTORY_FIT="${FACTORY_FIT_DIR}/factoryreset.fit"
        if [[ ! -e "$FACTORY_FIT" ]]; then
            echo "Saving current update file as factory default image"
            mkdir -p "${FACTORY_FIT_DIR}"
            cp "$FIT" "${FACTORY_FIT}"
        fi
    else
        fatal "Factory reset is now supported only from initramfs environment"
    fi
}

wb_update_fw_env_config()
{
    local config_file="/etc/fw_env.config"
    local device_name="/dev/mmcblk0"
    local offset size

    info "Reading uboot env offset/size from device tree..."

    local node=$(readlink -f "/proc/device-tree/wirenboard")
    if [[ -e "$node/uboot-env-offset" ]]; then
        offset=$(< "$node/uboot-env-offset" sed 's/\x0$//g' | tr '\000' ' ')
    else
        info "Could not read uboot-env-offset from device tree. Keeping old fw_env.config from rootfs"
        return 0
    fi

    if [[ -e "$node/uboot-env-size" ]]; then
        size=$(< "$node/uboot-env-size" sed 's/\x0$//g' | tr '\000' ' ')
    else
        info "Could not read uboot-env-size from device tree. Keeping old fw_env.config from rootfs"
        return 0
    fi

    cat > "$config_file" << EOF
# Configuration file for fw_(printenv/saveenv) utility.
# Up to two entries are valid, in this case the redundant
# environment sector is assumed present.
#
# XXX this configuration might miss a fifth parameter for the "Number of
# sectors"

# MTD device name   Device offset   Env. size   Flash sector size
$device_name        $offset             $size
EOF
    info "Successfully updated $config_file"
}

#---------------------------------------- main ----------------------------------------

prepare_env

# --fail flag allows to simulate failed update for testing purposes
if flag_set fail; then
    fatal "Update failed by request"
fi

wb_update_fw_env_config

if flag_set from-initramfs; then
    extend_tmpfs_size
    maybe_update_current_factory_tmpfs_size_fix
fi

check_firmware_compatible

if flag_set factoryreset; then
    if ! flag_set from-initramfs; then
        update_after_reboot
    else
        maybe_factory_reset
    fi
fi

if flag_set from-emmc-factoryreset; then
    maybe_trigger_original_factory_fit_to_restore_ab
fi

if flag_set force-compatible; then
    info "WARNING: Don't check compatibility. I hope you know what you're doing..."
else
    check_compatible || fatal "This update is incompatible with this device"
fi

if ! fit_blob_verify_hash rootfs; then
    fatal "rootfs blob hash verification failed"
else
    info "rootfs is valid, installing firmware update"
fi

# separate this from previous if to make it work
# without factoryreset after repartition
if ! flag_set from-initramfs; then
    if ! disk_layout_is_ab; then
        update_after_reboot
    fi
else
    if flag_set fail-in-bootlet; then
        fatal "Update failed by request"
    fi
fi

if ! flag_set from-initramfs && flag_set "force-repartition"; then
    update_current_factory_fit_if_not_compatible "single-rootfs wb8-debug-network-update-fix wrong-ab-layout-fix"
    update_after_reboot
fi

if ( ( flag_set "factoryreset" || flag_set "force-repartition" ) && ! flag_set "no-repartition" && ! disk_layout_is_extended); then
    maybe_repartition
fi

if disk_layout_is_ab; then
    select_new_partition
else
    info "Configuring environment for repartitioned eMMC"
    PART=2
    PREVIOUS_PART=nosuchpartition
fi

ROOT_PART=${ROOTDEV}p${PART}
info "Will install to $ROOT_PART"

if ! flag_set factoryreset; then
    ensure_no_downgrade
fi

cleanup_rootfs "$ROOT_PART"

MNT="$(mktemp -d)"
mount_rootfs "$ROOT_PART" "$MNT"
extract_rootfs "$MNT"

# Save serial number so we can use it later for logfile name
if flag_set mass-update; then
    populate_serial_and_fit_ver "$MNT"
fi

if ! flag_set no-certificates; then
    recover_certificates "$MNT"
fi

if ! flag_set no-postinst; then
    run_postinst "$MNT"

    if flag_set custom-postinst && [[ -d "$(dirname "$FIT")/install_update.postinst" ]]; then
        info "Running custom postinst scripts from $(dirname "$FIT")/install_update.postinst"
        run_postinst "$MNT" "$(dirname "$FIT")/install_update.postinst/"
    fi
fi

if flag_set copy-to-factory; then
    copy_this_fit_to_factory
elif flag_set factoryreset; then
    update_current_factory_fit_if_not_compatible "single-rootfs wb8-debug-network-update-fix wrong-ab-layout-fix"
fi

info "Switching to new rootfs"
fw_setenv mmcpart "$PART"
fw_setenv upgrade_available 1

info "Done!"
rm_fit
led_success || true
if flag_set mass-update; then
    beep_success
    log_mass_update
fi

trap_add maybe_reboot EXIT
