# Shared setup for the unit tests of install_update.sh.
#
# install_update.sh is normally sourced by wb-run-update, which provides
# flag_set, info, die, fit_prop_string and friends, and runs on a controller
# with eMMC partitions. Here both are replaced: the host functions by the
# stubs below, the disk by a directory with fake partition files. Commands
# touching the disk are stubs too: blockdev and fw_printenv answer from the
# fake partition files and $MMCPART; mount, umount, reboot, fw_setenv, chattr
# and the heavyweight install steps (see main_stubs) log their calls to
# $CALLS, checked with `called`.

INSTALL_UPDATE_SH="$BATS_TEST_DIRNAME/../utils/lib/wb-image-update/fit/install_update.sh"

setup_install_update() {
    WORKDIR=$(mktemp -d)
    export TMPDIR="$WORKDIR/tmp"
    export ROOTDEV="$WORKDIR/mmcblk0"
    export WEBUPD_DIR="$WORKDIR/webupd"             # /mnt/data/.wb-update on a controller
    export OS_RELEASE_FILE="$WORKDIR/os-release"    # /etc/os-release of the running system
    mkdir -p "$TMPDIR"
    echo "VERSION_CODENAME=trixie" > "$OS_RELEASE_FILE"

    CALLS="$WORKDIR/calls"
    : > "$CALLS"

    FLAGS=""                    # flags given to wb-run-update, e.g. " --from-initramfs"
    FIT_RELEASE_TARGET=""       # release-target property of the FIT being installed
    FIT_FIRMWARE_COMPATIBLE=""  # firmware-compatible property of the FIT
    declare -gA FIT_COMPAT_OF   # firmware-compatible per FIT basename, see fit_prop_string
    ROOTFS_CODENAME=""          # VERSION_CODENAME of the rootfs found on a mounted partition
    MMCPART=""                  # mmcpart variable in U-Boot environment

    export INSTALL_UPDATE_FUNCTIONS_ONLY=1
    # shellcheck source=/dev/null
    source "$INSTALL_UPDATE_SH"
    stub_install_steps
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

# part_fs <partition number>: directory holding the content of a fake partition
part_fs() {
    echo "$WORKDIR/fs/$(basename "$ROOTDEV")p$1"
}

# --- stubs for commands -----------------------------------------------------

blockdev() {
    [ "$1" = "--getsz" ] || return 1
    cat "$2.size"
}

# A fake partition is "mounted" by pointing the mountpoint at its content
# directory (see part_fs), so files written through the mountpoint can be
# checked after the call. A partition with a <dev>.nomount marker fails to mount.
mount() {
    echo "mount $*" >> "$CALLS"
    local args=("$@")
    local dev="${args[-2]}" mountpoint="${args[-1]}"
    case "$dev" in
        proc|configfs) return 0 ;;
    esac
    [ -e "$dev" ] || return 32
    [ ! -e "$dev.nomount" ] || return 32
    local content
    content=$(part_fs "${dev##*p}")
    command mkdir -p "$content/etc"
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

umount() { echo "umount $*" >> "$CALLS"; }
reboot() { echo "reboot $*" >> "$CALLS"; }
sync() { :; }

fw_printenv() {
    [ -n "$MMCPART" ] || return 1
    echo "mmcpart=$MMCPART"
}

fw_setenv() { echo "fw_setenv $*" >> "$CALLS"; }

# immutable attribute is kept as a <file>.immutable marker
chattr() {
    echo "chattr $*" >> "$CALLS"
    case "$1" in
        +i) touch "$2.immutable" ;;
        -i) rm -f "$2.immutable" ;;
    esac
}

lsattr() {
    local file="${*: -1}"
    [ -e "$file.immutable" ] && echo "Immutable $file" || echo "---- $file"
}

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
            local name="${FIT##*/}"
            if [ -n "$name" ] && [ -n "${FIT_COMPAT_OF[$name]+x}" ]; then
                echo "${FIT_COMPAT_OF[$name]}"
            else
                echo "$FIT_FIRMWARE_COMPATIBLE"
            fi ;;
    esac
}

# --- stubs for install steps that cannot run on the host --------------------
# Defined after install_update.sh is sourced, so they replace the real ones.

stub_install_steps() {
    ensure_uboot_ready_for_webupd() { :; }
    ensure_ab_rootfs_parttable() { echo "ensure_ab_rootfs_parttable" >> "$CALLS"; }
    ensure_extended_rootfs_parttable() { echo "ensure_extended_rootfs_parttable" >> "$CALLS"; }
    ensure_enlarged_rootfs_parttable() { echo "ensure_enlarged_rootfs_parttable" >> "$CALLS"; }
}

# main_stubs: replace every step of the main flow that touches real hardware
# or the FIT blob by a logging stub, so run_main exercises only the dispatch
# between them. update_after_reboot exits like the real one does.
main_stubs() {
    local fn
    for fn in maybe_fix_uboot_dynamic_env extend_tmpfs_size \
              maybe_update_current_factory_tmpfs_size_fix check_firmware_compatible \
              maybe_factory_reset maybe_trigger_original_factory_fit_to_restore_ab \
              check_compatible fit_blob_verify_hash maybe_repartition ensure_no_downgrade \
              cleanup_rootfs mount_rootfs extract_rootfs recover_certificates run_postinst \
              copy_this_fit_to_factory update_current_factory_fit_if_not_compatible \
              rm_fit led_success maybe_reboot; do
        eval "$fn() { echo \"$fn \$*\" >> \"\$CALLS\"; }"
    done
    update_after_reboot() { echo "update_after_reboot" >> "$CALLS"; exit 0; }
}

# run_main: execute the main flow of install_update.sh (everything after the
# INSTALL_UPDATE_FUNCTIONS_ONLY guard) with the functions defined so far.
# It ends with exit, so call it as `run isolated run_main`.
run_main() {
    eval "$(sed -n '/INSTALL_UPDATE_FUNCTIONS_ONLY/,$p' "$INSTALL_UPDATE_SH" | tail -n +2)"
}

# --- helpers for tests ------------------------------------------------------

in_bootlet() { FLAGS="$FLAGS --from-initramfs"; }

# use_fit <path>: the FIT being installed is a plain file at <path>
# (its content does not matter, properties come from fit_prop_string)
use_fit() {
    FIT="$1"
    command mkdir -p "$(dirname "$FIT")"
    echo "fit $FIT" > "$FIT"
}

# use_factory_fit <firmware-compatible>: an old factory FIT on the data partition
use_factory_fit() {
    FACTORY_FIT="$(part_fs 6)/.wb-restore/factoryreset.fit"
    command mkdir -p "${FACTORY_FIT%/*}"
    echo "old factory fit" > "$FACTORY_FIT"
    FIT_COMPAT_OF[factoryreset.fit]="$1"
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
