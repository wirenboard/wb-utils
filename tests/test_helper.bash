# Shared setup for install_update.sh unit tests.
#
# install_update.sh is normally sourced by wb-run-update, which provides
# flag_set, info, die, fit_prop_string and friends, and runs on a controller
# with eMMC partitions. Here both are replaced: the host functions by the
# stubs below, the disk by a directory with fake partition files, and the
# commands touching them (blockdev, mount, fw_printenv, reboot) by functions
# that log their calls to $CALLS.

INSTALL_UPDATE_SH="$BATS_TEST_DIRNAME/../utils/lib/wb-image-update/fit/install_update.sh"

setup_install_update() {
    WORKDIR=$(mktemp -d)
    export TMPDIR="$WORKDIR/tmp"
    export ROOTDEV="$WORKDIR/mmcblk0"
    mkdir -p "$TMPDIR"

    CALLS="$WORKDIR/calls"
    : > "$CALLS"

    export WEBUPD_DIR="$WORKDIR/webupd"   # /mnt/data/.wb-update on a controller

    FLAGS=""                    # flags given to wb-run-update, e.g. " --from-initramfs"
    declare -gA FIT_COMPAT_OF   # firmware-compatible property per FIT file, see fit_prop_string
    FIT_RELEASE_TARGET=""       # release-target property of the FIT being installed
    FIT_FIRMWARE_COMPATIBLE=""  # firmware-compatible property of the FIT
    ROOTFS_CODENAME=""          # VERSION_CODENAME of the rootfs found on a mounted partition
    MMCPART=""                  # mmcpart variable in U-Boot environment

    export INSTALL_UPDATE_FUNCTIONS_ONLY=1
    # shellcheck source=/dev/null
    source "$INSTALL_UPDATE_SH"
}

teardown_install_update() {
    rm -rf "$WORKDIR"
}

# --- fake eMMC -------------------------------------------------------------

# use_layout ab|single|extended
#
# Creates partition files next to $ROOTDEV with sizes (in 512-byte sectors)
# taken from the layout tables in install_update.sh.
use_layout() {
    rm -f "$ROOTDEV"p*
    case "$1" in
        ab)
            _part 2 2097152; _part 3 2097152; _part 5 524288; _part 6 117385216 ;;
        single)
            _part 2 4194300; _part 3 4; _part 5 524288; _part 6 117385216 ;;
        extended)
            _part 2 13137920; _part 3 1048576; _part 4 1048576 ;;
        *)
            echo "unknown layout $1" >&2; return 1 ;;
    esac
}

_part() {
    : > "${ROOTDEV}p$1"
    echo "$2" > "${ROOTDEV}p$1.size"
}

# --- stubs for commands -----------------------------------------------------

blockdev() {
    [ "$1" = "--getsz" ] || return 1
    cat "$2.size"
}

# A fake partition is "mounted" by pointing the mountpoint at its content
# directory (see part_fs), so files written through the mountpoint can be
# checked after the call.
mount() {
    echo "mount $*" >> "$CALLS"
    local args=("$@")
    local dev="${args[-2]}" mountpoint="${args[-1]}"
    case "$dev" in
        proc|configfs) return 0 ;;
    esac
    [ -e "$dev" ] || return 32
    local content
    content=$(part_fs "${dev##*p}")
    mkdir -p "$content/etc"
    if [ -n "$ROOTFS_CODENAME" ]; then
        echo "VERSION_CODENAME=$ROOTFS_CODENAME" > "$content/etc/os-release"
    fi
    rmdir "$mountpoint" 2>/dev/null || true
    ln -sfn "$content" "$mountpoint"
}

# prepare_env sets up configfs for the device tree; not on the test host
mkdir() {
    [ "${*: -1}" != /sys/kernel/config ] || return 0
    command mkdir "$@"
}

# part_fs <partition number>: directory holding the content of a fake partition
part_fs() {
    echo "$WORKDIR/fs/$(basename "$ROOTDEV")p$1"
}

umount() { echo "umount $*" >> "$CALLS"; }
reboot() { echo "reboot $*" >> "$CALLS"; }
sync() { :; }

fw_printenv() {
    [ -n "$MMCPART" ] || return 1
    echo "mmcpart=$MMCPART"
}

fw_setenv() { echo "fw_setenv $*" >> "$CALLS"; }

# --- stubs for functions provided by wb-run-update --------------------------

flag_set() { [[ " $FLAGS " == *" --$1 "* ]]; }
info() { echo ">>> $*" >&2; }
die() { echo "!!! $*" >&2; exit 1; }
led_failure() { :; }
mqtt_status() { :; }

fit_prop_string() {
    case "$2" in
        release-target) echo "$FIT_RELEASE_TARGET" ;;
        firmware-compatible)
            # the FIT may be addressed through a fake mountpoint, see mount
            local key
            key=$(readlink -f "$FIT" 2>/dev/null || echo "$FIT")
            echo "${FIT_COMPAT_OF[$key]:-$FIT_FIRMWARE_COMPATIBLE}" ;;
    esac
}

# --- helpers for tests ------------------------------------------------------

in_bootlet() { FLAGS="$FLAGS --from-initramfs"; }

# use_fit <path>: the FIT being installed is a plain file at <path>
# (its content does not matter, properties come from fit_prop_string)
use_fit() {
    FIT="$1"
    mkdir -p "$(dirname "$FIT")"
    echo "fit $FIT" > "$FIT"
}

# isolated <command>: run the command in a subshell without the traps bats
# installs, for functions that end with exit (their EXIT trap must run alone).
isolated() { ( trap - EXIT ERR; "$@" ); }

# not <command>: succeeds when the command fails.
# A plain "! command" does not fail a bats test unless it is the last line.
not() { if "$@"; then return 1; fi; }

# called <glob>: was a command matching the pattern logged by a stub?
# Example: called "mount * -o ro ${ROOTDEV}p2 *"
called() {
    local line
    while read -r line; do
        # shellcheck disable=SC2053
        [[ $line == $1 ]] && return 0
    done < "$CALLS"
    return 1
}
