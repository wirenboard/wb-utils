#!/usr/bin/env bats
#
# Flags files, external script, hand-off of a web update to the bootlet,
# factory FIT bookkeeping and the choice of repartitioning.
# These used to be checked on a bench by wb-release-tests/fwupdate_tests.

load test_helper

setup() {
    setup_install_update
    # console log redirection (exec > >(tee ...)) would swallow the test output
    FLAGS="--no-console-log"
    use_layout single
    use_fit "$WORKDIR/media/wb_update.fit"
}
teardown() { teardown_install_update; }

# --- flags files next to the FIT --------------------------------------------

@test "prepare_env: install_update.flags next to the FIT is appended to FLAGS" {
    echo "--fail --no-reboot" > "$WORKDIR/media/install_update.flags"

    prepare_env
    flag_set fail
    flag_set no-reboot
    flag_set no-console-log
}

@test "prepare_env: no flags file leaves FLAGS as given" {
    prepare_env
    [ "$FLAGS" == "--no-console-log" ]
}

@test "prepare_env: install_update.web.flags is read and kept in a running system" {
    echo "--factoryreset" > "$WORKDIR/media/install_update.web.flags"

    prepare_env
    flag_set factoryreset
    [ -e "$WORKDIR/media/install_update.web.flags" ]
}

@test "prepare_env: install_update.web.flags is read and removed in the bootlet" {
    in_bootlet
    echo "--factoryreset" > "$WORKDIR/media/install_update.web.flags"

    prepare_env
    flag_set factoryreset
    [ ! -e "$WORKDIR/media/install_update.web.flags" ]
}

@test "prepare_env: web update writes status and log to files instead of MQTT" {
    FLAGS="$FLAGS --from-webupdate"

    prepare_env
    mqtt_status "INFO hello"
    [ "$(cat "$WEBUPD_DIR/state/update.status")" == "INFO hello" ]
    [ "$(cat "$WEBUPD_DIR/state/update.log")" == "INFO hello" ]
}

# --- external script --------------------------------------------------------

@test "external script: install_update.sh next to the FIT is run instead of the update" {
    FLAGS="$FLAGS --external-script"
    echo "echo external script ran > '$WORKDIR/external.marker'" > "$WORKDIR/media/install_update.sh"

    run prepare_env
    [ "$status" -eq 0 ]
    [ -e "$WORKDIR/external.marker" ]
    [[ "$output" == *"Returned from external script, exiting"* ]]
}

@test "external script: a failing script is fatal" {
    FLAGS="$FLAGS --external-script"
    echo "false" > "$WORKDIR/media/install_update.sh"

    run prepare_env
    [ "$status" -ne 0 ]
    [[ "$output" == *"External script failed"* ]]
}

@test "external script: missing script is fatal" {
    FLAGS="$FLAGS --external-script"

    run prepare_env
    [ "$status" -ne 0 ]
    [[ "$output" == *"External script not found"* ]]
}

@test "external script: flag is ignored while already running inside the script" {
    FLAGS="$FLAGS --external-script"
    echo "false" > "$WORKDIR/media/install_update.sh"
    IS_IN_EXTERNAL_SCRIPT=1

    prepare_env
}

# --- hand-off of an update to the bootlet (web update, running system) ------

@test "update_after_reboot: FIT is moved to webupd.fit, wb_webupd is set, system reboots" {
    prepare_env

    run isolated update_after_reboot
    [ "$status" -eq 0 ]
    [ ! -e "$FIT" ]
    [ "$(cat "$WEBUPD_DIR/webupd.fit")" == "fit $FIT" ]
    [[ "$(cat "$WEBUPD_DIR/state/update.status")" == "ERROR Nothing happened after reboot"* ]]
    called "fw_setenv wb_webupd 1"
    called "reboot"
}

@test "update_after_reboot: --no-remove keeps the original FIT" {
    FLAGS="$FLAGS --no-remove"
    prepare_env

    run isolated update_after_reboot
    [ "$status" -eq 0 ]
    [ -e "$FIT" ]
    [ -e "$WEBUPD_DIR/webupd.fit" ]
}

@test "update_after_reboot: --no-reboot exits without rebooting" {
    FLAGS="$FLAGS --no-reboot"
    prepare_env

    run isolated update_after_reboot
    [ "$status" -eq 0 ]
    called "fw_setenv wb_webupd 1"
    not called "reboot*"
}

@test "update_after_reboot: FIT already at the webupd location is used in place" {
    prepare_env
    use_fit "$WEBUPD_DIR/webupd.fit"

    run isolated update_after_reboot
    [ "$status" -eq 0 ]
    [ -e "$WEBUPD_DIR/webupd.fit" ]
    called "fw_setenv wb_webupd 1"
}

# --- factory FIT bookkeeping on update --------------------------------------

@test "factory FIT: the installed FIT is stored as factory FIT when there is none" {
    FIT_FIRMWARE_COMPATIBLE="+single-rootfs "

    update_current_factory_fit_if_not_compatible "single-rootfs"
    [ "$(cat "$(part_fs 6)/.wb-restore/factoryreset.fit")" == "fit $FIT" ]
}

@test "factory FIT: a factory FIT supporting the required features is kept" {
    use_factory_fit "+single-rootfs "
    FIT_FIRMWARE_COMPATIBLE="+single-rootfs "

    run update_current_factory_fit_if_not_compatible "single-rootfs"
    [ "$status" -eq 0 ]
    [[ "$output" == *"keeping it"* ]]
    [ "$(cat "$FACTORY_FIT")" == "old factory fit" ]
    [ ! -e "$(part_fs 6)/.wb-restore/factoryreset.original.fit" ]
}

@test "factory FIT: an outdated factory FIT is replaced and kept as factoryreset.original.fit" {
    use_factory_fit "+single-rootfs "
    FIT_FIRMWARE_COMPATIBLE="+single-rootfs +uboot-dynamic-env "

    update_current_factory_fit_if_not_compatible "single-rootfs uboot-dynamic-env"
    [ "$(cat "$FACTORY_FIT")" == "fit $FIT" ]
    [ "$(cat "$(part_fs 6)/.wb-restore/factoryreset.original.fit")" == "old factory fit" ]
    not called "chattr *"
}

@test "factory FIT: an immutable factory FIT is made writable for the copy and immutable again" {
    use_factory_fit "+single-rootfs +fit-immutable-support "
    chattr +i "$FACTORY_FIT"
    : > "$CALLS"
    FIT_FIRMWARE_COMPATIBLE="+single-rootfs +uboot-dynamic-env +fit-immutable-support "

    update_current_factory_fit_if_not_compatible "single-rootfs uboot-dynamic-env"
    [ "$(cat "$FACTORY_FIT")" == "fit $FIT" ]
    [ -e "$FACTORY_FIT.immutable" ]
    # the factory FIT is addressed through the mountpoint, hence the glob
    [ "$(grep -c '^chattr' "$CALLS")" -eq 2 ]
    [[ "$(grep '^chattr' "$CALLS" | head -1)" == "chattr -i "*"/.wb-restore/factoryreset.fit" ]]
    [[ "$(grep '^chattr' "$CALLS" | tail -1)" == "chattr +i "*"/.wb-restore/factoryreset.fit" ]]
}

@test "factory FIT: an update lacking a required feature is refused" {
    use_factory_fit "+single-rootfs "
    FIT_FIRMWARE_COMPATIBLE="+single-rootfs "

    run update_current_factory_fit_if_not_compatible "single-rootfs uboot-dynamic-env"
    [ "$status" -ne 0 ]
    [[ "$output" == *"uboot-dynamic-env is required, but not supported"* ]]
    [ "$(cat "$FACTORY_FIT")" == "old factory fit" ]
}

@test "factory FIT: on the extended layout .wb-restore lives on the rootfs partition" {
    use_layout extended
    FIT_FIRMWARE_COMPATIBLE="+single-rootfs "

    update_current_factory_fit_if_not_compatible "single-rootfs"
    [ "$(cat "$(part_fs 2)/mnt/data/.wb-restore/factoryreset.fit")" == "fit $FIT" ]
    called "mount ${ROOTDEV}p2 *"
}

# --- which repartitioning a factory reset performs --------------------------

@test "maybe_repartition: default is enlarging the rootfs" {
    maybe_repartition
    called ensure_enlarged_rootfs_parttable
    not called ensure_ab_rootfs_parttable
    not called ensure_extended_rootfs_parttable
}

@test "maybe_repartition: --restore-ab-rootfs restores the A/B scheme" {
    FLAGS="$FLAGS --restore-ab-rootfs"

    maybe_repartition
    called ensure_ab_rootfs_parttable
    not called ensure_enlarged_rootfs_parttable
}

@test "maybe_repartition: --extend-rootfs switches to the extended layout" {
    FLAGS="$FLAGS --extend-rootfs"

    maybe_repartition
    called ensure_extended_rootfs_parttable
    not called ensure_enlarged_rootfs_parttable
}

@test "maybe_repartition: --extend-rootfs is ignored for web and factory FIT updates" {
    FLAGS="--extend-rootfs --from-webupdate"
    maybe_repartition
    FLAGS="--extend-rootfs --from-emmc-factoryreset"
    maybe_repartition

    not called ensure_extended_rootfs_parttable
    [ "$(grep -c ensure_enlarged_rootfs_parttable "$CALLS")" -eq 2 ]
}

@test "maybe_repartition: a failed repartition is fatal only for the explicit layouts" {
    ensure_ab_rootfs_parttable() { return 1; }
    ensure_extended_rootfs_parttable() { return 1; }
    ensure_enlarged_rootfs_parttable() { return 1; }

    run maybe_repartition
    [ "$status" -eq 0 ]
    [[ "$output" == *"Repartition failed, continuing without it"* ]]

    FLAGS="$FLAGS --restore-ab-rootfs"
    run maybe_repartition
    [ "$status" -ne 0 ]

    FLAGS="--no-console-log --extend-rootfs"
    run maybe_repartition
    [ "$status" -ne 0 ]
}
