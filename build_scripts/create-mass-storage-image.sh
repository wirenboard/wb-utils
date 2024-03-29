#!/bin/bash

BS="512"

if (( $# != 2 )); then
    >&2 echo -e "Usage:\n$0 mass_storage_contents_dir/ mass_storage.img"
    exit 1
else
    CONTENTS_DIR=$1
    IMAGE_FNAME=$2
    echo "Creating $IMAGE_FNAME from $CONTENTS_DIR"
fi

set -e

size=$(du -B $BS -s "$CONTENTS_DIR" | cut -f1)
if (( $size < 1024 )); then
    size=1024  # Windows 10 seems to have problems with images smaller than 512KB
else
    size=$(($size+1))
fi
echo "$IMAGE_FNAME: $size*$BS"
dd if=/dev/zero of="$IMAGE_FNAME" bs=$BS seek=$size count=0
mformat -i "$IMAGE_FNAME" -T $size -M $BS -v "WIRENBOARD"
GLOBIGNORE=$GLOBIGNORE; mcopy -i "$IMAGE_FNAME" "$CONTENTS_DIR"* ::
