#!/usr/bin/env bats
#
# The main flow of install_update.sh: which steps run for which flags and
# layouts. Every step that touches hardware or the FIT blob is a logging stub
# (see main_stubs in test_helper.bash), the dispatch between them is real.

load test_helper

setup() {
    setup_install_update
    main_stubs
    FLAGS="--no-console-log"
    use_layout single
    use_fit "$WORKDIR/media/wb_update.fit"
}
teardown() { teardown_install_update; }

# --- failing on request -----------------------------------------------------

@test "main: --fail aborts right after the environment is prepared" {
    FLAGS="$FLAGS --fail"

    run isolated run_main
    [ "$status" -ne 0 ]
    [[ "$output" == *"Update failed by request"* ]]
    not called "check_firmware_compatible*"
}

@test "main: --fail-in-bootlet aborts in the bootlet before the rootfs is touched" {
    in_bootlet
    FLAGS="$FLAGS --fail-in-bootlet"

    run isolated run_main
    [ "$status" -ne 0 ]
    [[ "$output" == *"Update failed by request"* ]]
    called "fit_blob_verify_hash rootfs"
    not called "cleanup_rootfs*"
}

@test "main: --fail-in-bootlet is ignored in a running system" {
    FLAGS="$FLAGS --fail-in-bootlet"

    run isolated run_main
    [ "$status" -eq 0 ]
    [[ "$output" != *"Update failed by request"* ]]
}

# --- running system: install in place on A/B, hand over to the bootlet otherwise

@test "main: running system on the single layout hands the update over to the bootlet" {
    run isolated run_main
    [ "$status" -eq 0 ]
    called "update_after_reboot"
    not called "extract_rootfs*"
}

@test "main: running system on the A/B layout installs into the other partition" {
    use_layout ab
    MMCPART=2

    run isolated run_main
    [ "$status" -eq 0 ]
    not called "update_after_reboot"
    called "ensure_no_downgrade*"
    called "cleanup_rootfs ${ROOTDEV}p3"
    called "mount_rootfs ${ROOTDEV}p3 *"
    called "extract_rootfs *"
    called "run_postinst *"
    called "fw_setenv mmcpart 3"
    called "fw_setenv upgrade_available 1"
    called "rm_fit*"
    called "maybe_reboot*"
}

@test "main: --force-repartition on A/B in a running system refreshes the factory FIT and hands over to the bootlet" {
    # on the single layout the hand-over happens earlier, before this branch is reached
    use_layout ab
    MMCPART=2
    FLAGS="$FLAGS --force-repartition"

    run isolated run_main
    [ "$status" -eq 0 ]
    called "update_current_factory_fit_if_not_compatible single-rootfs *"
    called "update_after_reboot"
}

# --- bootlet ----------------------------------------------------------------

@test "main: bootlet update installs to the single rootfs after the downgrade check" {
    in_bootlet

    run isolated run_main
    [ "$status" -eq 0 ]
    called "ensure_no_downgrade*"
    not called "maybe_factory_reset*"
    not called "maybe_repartition*"
    called "mount_rootfs ${ROOTDEV}p2 *"
    called "fw_setenv mmcpart 2"
    called "maybe_reboot*"
}

@test "main: bootlet factory reset wipes data, repartitions and skips the downgrade check" {
    in_bootlet
    FLAGS="$FLAGS --factoryreset"

    run isolated run_main
    [ "$status" -eq 0 ]
    called "maybe_factory_reset*"
    called "maybe_repartition*"
    not called "ensure_no_downgrade*"
    called "update_current_factory_fit_if_not_compatible single-rootfs *"
}

@test "main: factory reset does not repartition with --no-repartition" {
    in_bootlet
    FLAGS="$FLAGS --factoryreset --no-repartition"

    run isolated run_main
    [ "$status" -eq 0 ]
    not called "maybe_repartition*"
}

@test "main: factory reset never repartitions the extended layout" {
    in_bootlet
    use_layout extended
    FLAGS="$FLAGS --factoryreset"

    run isolated run_main
    [ "$status" -eq 0 ]
    not called "maybe_repartition*"
    called "mount_rootfs ${ROOTDEV}p2 *"
}

@test "main: restore from the factory FIT checks for an original A/B factory FIT" {
    in_bootlet
    FLAGS="$FLAGS --factoryreset --from-emmc-factoryreset"

    run isolated run_main
    [ "$status" -eq 0 ]
    called "maybe_trigger_original_factory_fit_to_restore_ab*"
}

# --- optional steps ---------------------------------------------------------

@test "main: --copy-to-factory stores the installed FIT as factory FIT" {
    in_bootlet
    FLAGS="$FLAGS --copy-to-factory"

    run isolated run_main
    [ "$status" -eq 0 ]
    called "copy_this_fit_to_factory*"
    not called "update_current_factory_fit_if_not_compatible*"
}

@test "main: --no-postinst and --no-certificates skip those steps" {
    in_bootlet
    FLAGS="$FLAGS --no-postinst --no-certificates"

    run isolated run_main
    [ "$status" -eq 0 ]
    not called "run_postinst*"
    not called "recover_certificates*"
    called "extract_rootfs *"
}

@test "main: --force-compatible skips the device compatibility check" {
    in_bootlet
    FLAGS="$FLAGS --force-compatible"

    run isolated run_main
    [ "$status" -eq 0 ]
    not called "check_compatible*"
}
