#!/bin/bash

# This script extracts device model from factory overlay and prints it to stdout.
# It works even in bootlet environment, so it can be used in install_update.sh.

set -e

EMMC=${EMMC:-/dev/mmcblk0}
TMPFILE=$(mktemp)
trap 'rm -f $TMPFILE' EXIT

# creating empty DTB to apply overlay to
echo "/dts-v1/; / { wirenboard {}; };" | dtc -I dts -O dtb -o "$TMPFILE"
dd "if=$EMMC" bs=512 skip=2016 count=32 | fdtoverlay -i "$TMPFILE" -o - - | fdtget -t s - /wirenboard factory-fdt
