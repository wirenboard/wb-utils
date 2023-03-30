#!/bin/bash

set -e

if [ ! -e /proc/self ]; then
    mount -t proc proc /proc
fi

if [ ! -e /dev/fd ]; then
    ln -s /proc/self/fd /dev/fd
fi

if [ ! -e /etc/mtab ]; then
    ln -s /proc/self/mounts /etc/mtab || true
fi

ensure_tools() {
    if [ -z "$TOOLPATH" ]; then
        export TOOLPATH=$(mktemp -d)
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

disk_layout_is_ab() {
    [ "$(blockdev --getsz /dev/mmcblk0p2)" -eq "$(blockdev --getsz /dev/mmcblk0p3)" ]
}

set_size() {
    sed "s#^\\($1.*size=\\s\\+\\)[0-9]\\+\\(.*\\)#\\1 $2\\2#"
}

set_start() {
    sed "s#^\\($1.*start=\\s\\+\\)[0-9]\\+\\(.*\\)#\\1 $2\\2#"
}

type mkfs_ext4 2>/dev/null | grep -q 'shell function' || {
    mkfs_ext4() {
        local part=$1
        local label=$2

        yes | mkfs.ext4 -L "$label" -E stride=2,stripe-width=1024 -b 4096 "$part"
    }
}
ensure_enlarged_rootfs_parttable() {
    if ! disk_layout_is_ab; then
        info "Partition table seems to be changed already, continue"
        return 0
    fi

    info "Unmounting everything"
    umount /dev/mmcblk0p2 >/dev/null 2>&1 || true
    umount /dev/mmcblk0p3 >/dev/null 2>&1 || true
    umount /dev/mmcblk0p6 >/dev/null 2>&1 || true

    info "Checking and repairing filesystem on /dev/mmcblk0p2"
    run_tool e2fsck -f -p /dev/mmcblk0p2; E2FSCK_RC=$?

    # e2fsck returns 1 and 2 if some errors were fixed, it's OK for us
    if [ "$E2FSCK_RC" -gt 2 ]; then
        info "Filesystem check failed, can't proceed with resizing"
        return 1
    fi

    info "Backing up old MBR (and partition table)"
    local mbr_backup
    mbr_backup=$(mktemp)
    dd if=/dev/mmcblk0 of="$mbr_backup" bs=512 count=1 || {
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

    sfdisk --dump /dev/mmcblk0 | \
        set_size  /dev/mmcblk0p2 "$ROOTFS_SIZE_BLOCKS" | \
        set_start /dev/mmcblk0p3 "$((ROOTFS_START_BLOCKS + ROOTFS_SIZE_BLOCKS))" | \
        set_size  /dev/mmcblk0p3 4 | \
        tee "$TEMP_DUMP" | \
        sfdisk -f /dev/mmcblk0 >/dev/null || {

        info "New parttable creation failed, restoring saved MBR backup"
        dd if="$mbr_backup" of=/dev/mmcblk0 oflag=direct conv=notrunc || true
        sync
        blockdev --rereadpt /dev/mmcblk0 || true
        return 1
    }

    sync
    blockdev --rereadpt /dev/mmcblk0 || true

    if [ "$(blockdev --getsz /dev/mmcblk0p2)" != "$ROOTFS_SIZE_BLOCKS" ]; then
        info "New parttable is not applied, restoring saved MBR backup and exit"
        dd if="$mbr_backup" of=/dev/mmcblk0 oflag=direct conv=notrunc || true
        sync
        blockdev --rereadpt /dev/mmcblk0 || true
        die "Failed to apply a new partition table"
    fi

    info "Expanding filesystem on this partition"
    local e2fs_undofile
    e2fs_undofile=$(mktemp)
    run_tool resize2fs -z "$e2fs_undofile" /dev/mmcblk0p2 || {
        info "Filesystem expantion failed, restoring everything"
        run_tool e2undo "$e2fs_undofile" /dev/mmcblk0p2 || true
        dd if="$mbr_backup" of=/dev/mmcblk0 oflag=direct conv=notrunc || true
        sync
        blockdev --rereadpt /dev/mmcblk0 || true
        return 1
    }

    info "Repartition is done!"
}

ensure_ab_rootfs_parttable() {
    if disk_layout_is_ab; then
        info "Partition table seems to be A/B, continue"
        return 0
    fi

    info "Unmounting everything"
    umount /dev/mmcblk0p2 >/dev/null 2>&1 || true
    umount /dev/mmcblk0p3 >/dev/null 2>&1 || true
    umount /dev/mmcblk0p6 >/dev/null 2>&1 || true

    info "Checking and repairing filesystem on /dev/mmcblk0p2"
    run_tool e2fsck -f -p /dev/mmcblk0p2; E2FSCK_RC=$?

    # e2fsck returns 1 and 2 if some errors were fixed, it's OK for us
    if [ "$E2FSCK_RC" -gt 2 ]; then
        info "Filesystem check failed, can't proceed with resizing"
        return 1
    fi

    info "Shrinking filesystem on /dev/mmcblk0p2"
    local e2fs_undofile
    e2fs_undofile=$(mktemp)
    run_tool resize2fs -z "$e2fs_undofile" /dev/mmcblk0p2 262144 || {
        info "Filesystem expantion failed, restoring everything"
        run_tool e2undo "$e2fs_undofile" /dev/mmcblk0p2 || true
        sync
        return 1
    }

    info "Backing up old MBR (and partition table)"
    local mbr_backup
    mbr_backup=$(mktemp)
    dd if=/dev/mmcblk0 of="$mbr_backup" bs=512 count=1 || {
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

    sfdisk --dump /dev/mmcblk0 | \
        set_size  /dev/mmcblk0p2 "$ROOTFS_SIZE_BLOCKS" | \
        set_start /dev/mmcblk0p3 "$((ROOTFS_START_BLOCKS + ROOTFS_SIZE_BLOCKS))" | \
        set_size  /dev/mmcblk0p3 "$ROOTFS_SIZE_BLOCKS" | \
        tee "$TEMP_DUMP" | \
        sfdisk -f /dev/mmcblk0 >/dev/null || {

        info "New parttable creation failed, restoring saved MBR backup"
        dd if="$mbr_backup" of=/dev/mmcblk0 oflag=direct conv=notrunc || true
        sync
        blockdev --rereadpt /dev/mmcblk0 || true
        return 1
    }

    sync
    blockdev --rereadpt /dev/mmcblk0 || true

    if [ "$(blockdev --getsz /dev/mmcblk0p2)" != "$ROOTFS_SIZE_BLOCKS" ]; then
        info "New parttable is not applied, restoring saved MBR backup and exit"
        dd if="$mbr_backup" of=/dev/mmcblk0 oflag=direct conv=notrunc || true
        sync
        blockdev --rereadpt /dev/mmcblk0 || true
        die "Failed to apply a new partition table"
    fi

    info "Creating filesystem on second partition"
    mkfs_ext4 /dev/mmcblk0p3 "rootfs" || {
        info "Creating new filesystem on second partition failed!"
        info "Restoring saved MBR backup and exit"
        dd if="$mbr_backup" of=/dev/mmcblk0 oflag=direct conv=notrunc || true
        sync
        blockdev --rereadpt /dev/mmcblk0 || true
        die "Failed to create filesystem on new rootfs, exiting"
    }

    info "Repartition is done!"
}

cleanup_rootfs() {
    local ROOT_PART="$1"
    local mountpoint
    mountpoint="$(mktemp -d)"

    mount -t ext4 "$ROOT_PART" "$mountpoint" >/dev/null 2>&1 || die "Unable to mount root filesystem"

    info "Cleaning up $ROOT_PART"
    rm -rf /tmp/empty && mkdir /tmp/empty
    if which rsync >/dev/null; then
        info "Cleaning up using rsync"
        rsync -a --delete /tmp/empty/ "$mountpoint" || die "Failed to cleanup rootfs"
    else
        info "Can't find rsync, cleaning up using rm -rf (may be slower)"
        rm -rf $mountpoint/..?* $mountpoint/.[!.]* $mountpoint/* || die "Failed to cleanup rootfs"
    fi

    umount "$mountpoint" || true
}

# FIXME: transitional definitions which are being moved to wb-run-update
HIDDENFS_PART=/dev/mmcblk0p1
HIDDENFS_OFFSET=$((8192*512))  # 8192 blocks of 512 bytes
DEVCERT_NAME="device.crt.pem"
INTERM_NAME="intermediate.crt.pem"
ROOTFS_CERT_PATH="/etc/ssl/certs/device_bundle.crt.pem"

type fit_prop_string 2>/dev/null | grep -q 'shell function' || {
    fit_prop_string() {
        fit_prop "$@" | tr -d '\0'
    }
}



check_compatible() {
	local fit_compat=`fit_prop_string / compatible`
	[[ -z "$fit_compat" || "$fit_compat" == "unknown" ]] && return 0
	for compat in `tr < /proc/device-tree/compatible  '\000' '\n'`; do
		[[ "$fit_compat" == "$compat" ]] && return 0
	done
	return 1
}

if flag_set "force-compatible"; then
	info "WARNING: Don't check compatibility. I hope you know what you're doing..."
else
	check_compatible || die "This update is incompatible with this device"
fi

fit_blob_verify_hash rootfs

info "Installing firmware update"

MNT="$TMPDIR/rootfs"
ACTUAL_DEB_RELEASE=""

ROOT_DEV='mmcblk0'
if [[ -e "/dev/root" ]]; then
	PART=`readlink /dev/root`
	PART=${PART##*${ROOT_DEV}p}
else
	info "Getting mmcpart from U-Boot environment"
	PART=$(fw_printenv mmcpart | sed 's/.*=//') || PART=""
fi

case "$PART" in
	2)
		PART=3
		PART_NOW=2
		;;
	3)
		PART=2
		PART_NOW=3
		;;
	*)
		flag_set from-initramfs && {
			info "Update is started from initramfs and unable to determine active rootfs partition, will overwrite rootfs0"
			PART=2
			PART_NOW=3
		} || {
			die "Unable to determine second rootfs partition (current is $PART)"
		}
		;;
esac

RESTORE_AB_FLAG=
if flag_set from-initramfs && [ -e "$(dirname "$FIT")/restore_ab_rootfs" ];  then
    RESTORE_AB_FLAG=true
fi

if flag_set "factoryreset" && ! flag_set "no-repartition"; then
    if [ -n "$RESTORE_AB_FLAG" ]; then
        cleanup_rootfs /dev/mmcblk0p2
        info "restoring A/B scheme as requested"
        if ensure_ab_rootfs_parttable; then
            info "A/B scheme restored!"
        else
            die "Failed to restore A/B scheme"
        fi
    else
        if ensure_enlarged_rootfs_parttable; then
            info "rootfs enlarged!"
        else
            info "Repartition failed, continuing without it"
        fi
    fi
fi

# separate this from previous if to make it work
# without factoryreset after repartition
if ! disk_layout_is_ab; then

    # TODO: maybe remove it when web update will work
    if ! flag_set from-initramfs; then
        die "Web UI update does not work after repartition, please use USB drive!"
    fi

    info "Configuring environment for repartitioned eMMC"
    PART=2
    PART_NOW=nosuchpartition
fi

ROOT_PART=/dev/${ROOT_DEV}p${PART}
info "Will install to $ROOT_PART"

rm -rf "$MNT" && mkdir "$MNT" || die "Unable to create mountpoint $MNT"

actual_rootfs=/dev/${ROOT_DEV}p${PART_NOW}
if flag_set from-initramfs ; then
    if [[ -e "$actual_rootfs" ]]; then
        info "Temporarily mount actual rootfs $actual_rootfs to check os-release"
        mount -t ext4 $actual_rootfs $MNT 2>&1 >/dev/null && {
            sync
            ACTUAL_DEB_RELEASE="$(MNT="$MNT" bash -c 'source "$MNT/etc/os-release"; echo $VERSION_CODENAME')"
            umount -f $actual_rootfs 2>&1 >/dev/null || true
        } || true
    fi
else
    ACTUAL_DEB_RELEASE="$(bash -c 'source "/etc/os-release"; echo $VERSION_CODENAME')"
fi

info "Mounting $ROOT_PART at $MNT"
mount -t ext4 "$ROOT_PART" "$MNT" 2>&1 >/dev/null|| die "Unable to mount root filesystem"

upcoming_deb_release="$(fit_prop_string / release-target | sed 's/wb[[:digit:]]\+\///')"
info "Debian: $ACTUAL_DEB_RELEASE -> $upcoming_deb_release"
if [ "$ACTUAL_DEB_RELEASE" = "bullseye" ] && [ "$upcoming_deb_release" = "stretch" ]; then
    if ! flag_set factoryreset; then
        >&2 cat <<EOF
##############################################################################

    ROLLBACK FROM $ACTUAL_DEB_RELEASE TO $upcoming_deb_release REQUESTED

                    Due to major Debian release changes,
                this operation is allowed only via FACTORYRESET.

    Rename .fit file to "wbX_update_FACTORYRESET.fit" ->
    put renamed file to usb-drive ->
    ensure, there is only one .fit file on usb-drive ->
    insert usb-drive to controller and reboot ->
    follow further factoryreset instructions.

##############################################################################
EOF
        if flag_set from-initramfs; then
            led_failure
            bash -c 'source /lib/libupdate.sh; buzzer_init; buzzer_on; sleep 1; buzzer_off'
            info "Rebooting..."
            reboot -f
        else
            die "Aborting..."
        fi
    fi
fi

cleanup_rootfs "$ROOT_PART"

info "Extracting files to new rootfs"
pushd "$MNT"
blob_size=`fit_blob_size rootfs`
(
	echo 0
	fit_blob_data rootfs | pv -n -s "$blob_size" | tar xzp || die "Failed to extract rootfs"
) 2>&1 | mqtt_progress "$x"
popd

if ! flag_set no-certificates; then
    info "Recovering device certificates"
    HIDDENFS_MNT=$TMPDIR/hiddenfs
    mkdir -p $HIDDENFS_MNT

    # make loop device
    LO_DEVICE=`losetup -f`
    losetup -r -o $HIDDENFS_OFFSET $LO_DEVICE $HIDDENFS_PART ||
        die "Failed to add loopback device"

    if mount $LO_DEVICE $HIDDENFS_MNT 2>&1 >/dev/null; then
        cat $HIDDENFS_MNT/$INTERM_NAME $HIDDENFS_MNT/$DEVCERT_NAME > $MNT/$ROOTFS_CERT_PATH ||
            info "WARNING: Failed to copy device certificate bundle into new rootfs. Please report it to info@contactless.ru"
        umount $HIDDENFS_MNT
        sync
    else
        info "WARNING: Failed to find certificates of device. Please report it to info@contactless.ru"
    fi
fi

if ! flag_set no-postinst; then
    info "Mount /dev, /proc and /sys to rootfs"
    mount -o bind /dev "$MNT/dev"
    mount -o bind /proc "$MNT/proc"
    mount -o bind /sys "$MNT/sys"

    POSTINST_DIR="$MNT/usr/lib/wb-image-update/postinst/"
    if [[ -d "$POSTINST_DIR" ]]; then
        info "Running post-install scripts"

        POSTINST_FILES="$(find "$POSTINST_DIR" -maxdepth 1 -type f | sort)"
        for file in $POSTINST_FILES; do
            info "> Processing $file"
            FIT="$FIT" "$file" "$MNT" "$FLAGS" || true
        done
    fi

    info "Unmounting /dev, /proc and /sys from rootfs"
    umount "$MNT/dev"
    umount "$MNT/proc"
    umount "$MNT/sys"
fi

info "Switching to new rootfs"
fw_setenv mmcpart $PART
fw_setenv upgrade_available 1

info "Done!"
rm_fit
led_success || true

if ! flag_set no-reboot; then
    info "Unmounting new rootfs"
    umount $MNT
    sync; sync

    info "Reboot system"
    mqtt_status REBOOT
    trap EXIT
    flag_set "from-initramfs" && {
        sync
        reboot -f
    } || reboot
fi
exit 0
