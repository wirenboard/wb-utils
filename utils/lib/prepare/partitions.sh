. /usr/lib/wb-utils/prepare/vars.sh

# static vars for this part
_TOTAL_SECTORS=0
_PART_START=0

MB=1024*1024

wb_get_partition_start()
{
    local part=${WB_STORAGE}p$1
    fdisk -u sectors -l $WB_STORAGE |
        sed -rn "s#^${part}\\s+([0-9]+).*#\\1#p"
}

# Generates single partition definition line for sfdisk.
# Increments _PART_START variable to point to the start of the next partition
# (special case is Extended (5) fstype, which increments _PART_START by 2048 sectors)
# Args:
# - size in megabytes (or '' to use all remaining space to the end)
# - filesystem type (looks like not really matters). when omitted, defaults to 83 (Linux)
_wb_partition()
{
    [[ -z "$1" ]] &&
        local size=$[_TOTAL_SECTORS-_PART_START] ||
        local size=$[$1*MB/WB_SECTOR_SIZE]
    local fstype=${2:-83}
    [[ "$fstype" == 53 ]] && PART_START=2048
    echo "$_PART_START $size $fstype"
    [[ "$fstype" == 82 ]] && ((size+=2048))
    [[ "$fstype" == 5 ]] && ((_PART_START+=2048)) || ((_PART_START+=$size))
}


wb_make_partitions() {
    local storage=$1
    local rootfs_size_mb=$2

    _TOTAL_SECTORS=$[`sfdisk -s $WB_STORAGE`*2]

    # mx23 and mx28 have different boot image search methods, so keep existing uboot
    _PART_START=`wb_get_partition_start 1`

    # in case if we have broken partition table, restore default value
    _PART_START=${PART_START:=$WB_FIRSTPART_START}

    sfdisk --no-reread --Linux -u S --dump $storage > /tmp/partitions_backup
    dd if=/dev/zero of=$storage bs=512 count=1 2>&1 >/dev/null
    local erase_sectors=''
    {
        _wb_partition 16 53    # uboot
        _wb_partition ${rootfs_size_mb}     # rootfs0
        _wb_partition ${rootfs_size_mb}     # rootfs1
        _wb_partition '' 5     # <extended>
        _wb_partition 256 82   # swap
        _wb_partition ''       # data
    } | sfdisk --no-reread --Linux -u S $storage || true
    # FIXME: sfdisk succesfully writes partition table, but returns error
    # because it can't reread partitions on mounted disk, so just bypass error
    # handling.
    #{
    #    info "Failed, sfdisk returned $?"
    #    info "Restoring old partition table"
    #    sfdisk --no-reread --Linux --in-order -u S $storage < /tmp/partitions_backup
    #    rm -f /tmp/partitions_backup
    #    die "Prepare partitions failed"
    #}
    rm -f /tmp/partitions_backup
}
