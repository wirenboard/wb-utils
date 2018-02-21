wb_make_partitions() {
    local storage=$1
    local rootfs_size=$2

    sfdisk --no-reread --Linux --in-order -u S --dump $storage > /tmp/partitions_backup
    dd if=/dev/zero of=$storage bs=512 count=1 2>&1 >/dev/null
    local erase_sectors=''
    {
        wb_partition 16 53    # uboot
        wb_partition ${rootfs_size}     # rootfs0
        wb_partition ${rootfs_size}     # rootfs1
        wb_partition '' 5     # <extended>
        wb_partition 256 82   # swap
        wb_partition ''       # data
    } | sfdisk --no-reread --Linux --in-order -u S $storage || true
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
