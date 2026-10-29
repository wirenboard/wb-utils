#!/usr/bin/env bats
#
# Checks done by wb-watch-update before an uploaded FIT is handed to wb-run-update.

load test_helper   # for `not`; the install_update.sh harness is not set up here

WB_WATCH_UPDATE="$BATS_TEST_DIRNAME/../utils/bin/wb-watch-update"

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
    not check_fully_received "$WORKDIR/webupd.fit"
}

@test "check_fully_received: an empty file is rejected" {
    : > "$WORKDIR/webupd.fit"
    not check_fully_received "$WORKDIR/webupd.fit"
}

@test "fw_compatible: reads the firmware-compatible property out of the FIT file" {
    # fit_info reports where a property lives in the file; the property is then cut
    # out of the file itself, so a fake fit_info plus a crafted file exercise fit_prop
    local compat="+single-rootfs +fit-factory-reset "
    FIT="$WORKDIR/webupd.fit"
    printf 'hdr%s\0tail' "$compat" > "$FIT"
    command mkdir -p "$WORKDIR/bin"
    cat > "$WORKDIR/bin/fit_info" <<SHIM
#!/bin/sh
[ "\$2" = "$FIT" ] && [ "\$4" = "/" ] && [ "\$6" = "firmware-compatible" ] || exit 1
echo "LEN: $(( ${#compat} + 1 ))"
echo "OFF: 3"
SHIM
    chmod +x "$WORKDIR/bin/fit_info"
    PATH="$WORKDIR/bin:$PATH"

    [ "$(fit_prop_string / firmware-compatible)" == "$compat" ]
    fw_compatible fit-factory-reset
    not fw_compatible update-from-cloud
    not fw_compatible single
}
