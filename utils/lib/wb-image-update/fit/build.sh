#!/bin/bash
set -e

# This script runs on image creation stage and builds install_update.sh

if ! which policy-rc.d; then
    echo "You don't need this, please go away"
    exit 1
fi

. /usr/lib/wb-utils/wb_env.sh
wb_source "of"

if ! of_machine_match "wirenboard,wirenboard-720"; then
    echo "Single rootfs scheme is not supported on this target, skipping install_update.sh build"
    exit 0
fi

BUILDDIR="$(mktemp -d)"

cleanup() {
    rm -rf "$BUILDDIR"
}

trap cleanup EXIT 

install_dir() {
        echo "dir $1"
        mkdir -p "$BUILDDIR/$1"
}

install_file() {
        local src="$1"
        local dst="$2"

        local dstdir
        dstdir=$(dirname "$dst")
        [[ -d "$BUILDDIR/$dstdir" ]] || install_dir "$dstdir"

        echo "file $dst <- $src"
        cp "$src" "$BUILDDIR/$dst"
}

install_from_rootfs() {
        local src="$1"
        local dst="$2"

        [[ -z "$dst" ]] && {
                dst="$src"
                shift
        }
        install_file "$ROOTFS/$src" "$dst"

        # If file is executable, need to get its shared lib dependencies too
        if [[ -x "$ROOTFS/$src" ]]; then
                ldd "$src" |
                sed -rn 's#[^/]*(/[^ ]*).*#\1#p' |
                while read -r lib; do
                        [[ -e "$BUILDDIR/$lib" ]] || install_from_rootfs "$lib"
                done
        fi
}

FROM_ROOTFS=(
    /sbin/resize2fs
    /sbin/e2undo
    /sbin/e2fsck
    /sbin/e4defrag
)

for file in "${FROM_ROOTFS[@]}"; do
    install_from_rootfs "$file"
done

mkdir -p /var/lib/wb-image-update

cp /usr/lib/wb-image-update/fit/install_update.sh /var/lib/wb-image-update/install_update.sh
cd "$BUILDDIR" && tar cvzf /var/lib/wb-image-update/deps.tar.gz .

echo "+single-rootfs " > /var/lib/wb-image-update/firmware-compatible
