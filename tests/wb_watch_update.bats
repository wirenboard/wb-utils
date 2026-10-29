#!/usr/bin/env bats
#
# Checks done by wb-watch-update before an uploaded FIT is handed to wb-run-update.

WB_WATCH_UPDATE="$BATS_TEST_DIRNAME/../utils/bin/wb-watch-update"
UPDATE_FIT_END_SIGNATURE="__WB_UPDATE_FIT_END__"

setup() {
    WORKDIR=$(mktemp -d)
    export WB_WATCH_UPDATE_FUNCTIONS_ONLY=1
    # shellcheck source=/dev/null
    source "$WB_WATCH_UPDATE"
}
teardown() { rm -rf "$WORKDIR"; }

@test "check_fully_received: a FIT ending with the end signature is complete" {
    printf 'fit data %s' "$UPDATE_FIT_END_SIGNATURE" > "$WORKDIR/webupd.fit"
    check_fully_received "$WORKDIR/webupd.fit"
}

@test "check_fully_received: a truncated upload is rejected" {
    printf 'fit data %s' "$UPDATE_FIT_END_SIGNATURE" | head -c -3 > "$WORKDIR/webupd.fit"
    ! check_fully_received "$WORKDIR/webupd.fit"
}

@test "check_fully_received: an empty file is rejected" {
    : > "$WORKDIR/webupd.fit"
    ! check_fully_received "$WORKDIR/webupd.fit"
}

@test "fw_compatible: reads the feature list of the FIT in \$FIT" {
    fit_prop_string() { echo "+single-rootfs +fit-factory-reset "; }
    FIT="$WORKDIR/webupd.fit"
    fw_compatible fit-factory-reset
    ! fw_compatible update-from-cloud
}
