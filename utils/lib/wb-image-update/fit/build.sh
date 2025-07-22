#!/bin/bash
set -e

# This script runs during rootfs build.
#
# It collects all the files (and their binary deps) needed for install_update.sh
# (such as resize2fs and e2fsck) which are not present in a bootlet.
#
# These files are archived in /var/lib/wb-image-update/deps.tar.gz.
# install_update.sh extracts this archive from rootfs tarball and
# use its contents as chroot environment to run resize2fs and e2fsck.
#
# Image builder script takes install_update.sh from /var/lib/wb-image-update
# (so it may be modified during rootfs build), so this script puts it there too.

if ! which policy-rc.d; then
    echo "You don't need this, please go away"
    exit 1
fi

. /usr/lib/wb-utils/wb_env.sh
wb_source "of"

BUILDDIR="$(mktemp -d)"
IMAGEUPDATE_DIR=/var/lib/wb-image-update

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
    install_file "$src" "$dst"

    # If file is executable, need to get its shared lib dependencies too
    if [[ -x "$src" ]]; then
        ldd "$src" |
        sed -rn 's#[^/]*(/[^ ]*).*#\1#p' |
        while read -r lib; do
            [[ -e "$BUILDDIR/$lib" ]] || install_from_rootfs "$lib"
        done
    fi
}

FROM_ROOTFS=(
    /sbin/resize2fs
    /sbin/dumpe2fs
    /sbin/tune2fs
    /sbin/e2undo
    /sbin/e2fsck
    /sbin/e4defrag
)

for file in "${FROM_ROOTFS[@]}"; do
    install_from_rootfs "$file"
done

mkdir -p $IMAGEUPDATE_DIR

cp /usr/lib/wb-image-update/fit/install_update.sh $IMAGEUPDATE_DIR/install_update.sh
cd "$BUILDDIR" && tar cvzf $IMAGEUPDATE_DIR/deps.tar.gz .

{
    echo -n "+single-rootfs "
    echo -n "+fit-factory-reset "
    echo -n "+force-repartition "
    echo -n "+repartition-ramsize-fix "
    echo -n "+fit-immutable-support "
    echo -n "+wb8-debug-network-update-fix "
    echo -n "+wrong-ab-layout-fix "
} >> $IMAGEUPDATE_DIR/firmware-compatible

if of_machine_match "wirenboard,wirenboard-8xx"; then
    KERNEL_IMAGE="Image.gz"
else
    KERNEL_IMAGE="zImage"
fi

if [[ ! -f "$IMAGEUPDATE_DIR/$KERNEL_IMAGE" ]] || [[ ! -f "$IMAGEUPDATE_DIR/boot.dtb" ]]; then
    echo "bootlet is not found, something went wrong"
    exit 1
fi
