#!/usr/bin/env bats

load test_helper

setup() { setup_install_update; }
teardown() { teardown_install_update; }

# --- disk layout detection --------------------------------------------------

@test "A/B layout: two equal rootfs partitions, data partition present" {
    use_layout ab
    disk_layout_is_ab
    not disk_layout_is_extended
}

@test "single layout: second rootfs is a stub, data partition present" {
    use_layout single
    not disk_layout_is_ab
    not disk_layout_is_extended
}

@test "extended layout: no data partition" {
    use_layout extended
    not disk_layout_is_ab
    disk_layout_is_extended
}

# --- choice of the partition to install to (A/B) ----------------------------

@test "select_new_partition: installs next to the running one" {
    MMCPART=2
    select_new_partition
    [ "$PART" = 3 ]
    [ "$PREVIOUS_PART" = 2 ]

    MMCPART=3
    select_new_partition
    [ "$PART" = 2 ]
    [ "$PREVIOUS_PART" = 3 ]
}

@test "select_new_partition: unknown mmcpart in bootlet falls back to rootfs0" {
    in_bootlet
    select_new_partition
    [ "$PART" = 2 ]
    [ "$PREVIOUS_PART" = 3 ]
}

@test "select_new_partition: unknown mmcpart in running system is fatal" {
    run select_new_partition
    [ "$status" -ne 0 ]
}

# --- FIT compatibility flags ------------------------------------------------

@test "fw_compatible: matches whole feature names only" {
    FIT_FIRMWARE_COMPATIBLE="+single-rootfs +extended-rootfs "
    fw_compatible single-rootfs
    fw_compatible extended-rootfs
    not fw_compatible single
    not fw_compatible fit-factory-reset
}

# --- Debian downgrade protection ----------------------------------------------

@test "get_release_version: known Debian codenames" {
    [ "$(get_release_version stretch)" = 9 ]
    [ "$(get_release_version bullseye)" = 11 ]
    [ "$(get_release_version trixie)" = 13 ]
    not get_release_version forky
}

@test "running system: downgrade is refused without factory reset" {
    # the running system is the test host, its /etc/os-release is used as is
    local host_release
    host_release=$(. /etc/os-release && echo "$VERSION_CODENAME")
    get_release_version "$host_release" >/dev/null || skip "host Debian release $host_release is not known to install_update.sh"
    [ "$host_release" != stretch ] || skip "nothing to downgrade to from stretch"

    FIT_RELEASE_TARGET="wb7/stretch"
    run ensure_no_downgrade
    [ "$status" -ne 0 ]
    [[ "$output" == *"Rollback from $host_release to stretch is not allowed"* ]]
    not called "reboot *"
}

@test "running system: same release is allowed" {
    local host_release
    host_release=$(. /etc/os-release && echo "$VERSION_CODENAME")
    get_release_version "$host_release" >/dev/null || skip "host Debian release $host_release is not known to install_update.sh"

    FIT_RELEASE_TARGET="wb7/$host_release"
    ensure_no_downgrade
}

@test "bootlet, A/B: installed release is read from the running partition" {
    in_bootlet
    use_layout ab
    PREVIOUS_PART=3
    ROOTFS_CODENAME=trixie
    FIT_RELEASE_TARGET="wb7/bullseye"

    run ensure_no_downgrade
    [ "$status" -ne 0 ]
    [[ "$output" == *"Rollback from trixie to bullseye is not allowed"* ]]
    called "mount * ${ROOTDEV}p3 *"
    called "reboot -f"
}

@test "bootlet, single: installed release is read from the only rootfs partition" {
    in_bootlet
    use_layout single
    PREVIOUS_PART=nosuchpartition
    ROOTFS_CODENAME=trixie
    FIT_RELEASE_TARGET="wb7/bullseye"

    run ensure_no_downgrade
    [ "$status" -ne 0 ]
    [[ "$output" == *"Rollback from trixie to bullseye is not allowed"* ]]
    called "mount * ${ROOTDEV}p2 *"
}

@test "bootlet, extended: rootfs partition is mounted read-only and released by mountpoint" {
    # on extended layout the bootlet already has the rootfs partition mounted,
    # so the check must not touch it: read-only mount, umount of its own mountpoint
    in_bootlet
    use_layout extended
    PREVIOUS_PART=nosuchpartition
    ROOTFS_CODENAME=trixie
    FIT_RELEASE_TARGET="wb8/bullseye"

    run ensure_no_downgrade
    [ "$status" -ne 0 ]
    [[ "$output" == *"Rollback from trixie to bullseye is not allowed"* ]]
    called "mount * -o ro ${ROOTDEV}p2 $TMPDIR/*"
    called "umount $TMPDIR/*"
    not called "umount * ${ROOTDEV}p2*"
}

@test "bootlet: upgrade and reinstall of the same release are allowed" {
    in_bootlet
    use_layout single
    PREVIOUS_PART=nosuchpartition
    ROOTFS_CODENAME=bullseye

    FIT_RELEASE_TARGET="wb7/trixie"
    ensure_no_downgrade

    FIT_RELEASE_TARGET="wb7/bullseye"
    ensure_no_downgrade
}

@test "bootlet: factory reset allows downgrade" {
    in_bootlet
    FLAGS="$FLAGS --factoryreset"
    use_layout single
    PREVIOUS_PART=nosuchpartition
    ROOTFS_CODENAME=trixie
    FIT_RELEASE_TARGET="wb7/bullseye"

    ensure_no_downgrade
}

@test "bootlet: unreadable installed rootfs skips the check with a warning" {
    in_bootlet
    use_layout ab
    PREVIOUS_PART=3
    rm "${ROOTDEV}p3"
    FIT_RELEASE_TARGET="wb7/bullseye"

    run ensure_no_downgrade
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipping downgrade check"* ]]
}

@test "unknown release in FIT skips the check with a warning" {
    in_bootlet
    use_layout single
    PREVIOUS_PART=nosuchpartition
    ROOTFS_CODENAME=trixie
    FIT_RELEASE_TARGET="wb7/forky"

    run ensure_no_downgrade
    [ "$status" -eq 0 ]
    [[ "$output" == *"skipping downgrade check"* ]]
}
