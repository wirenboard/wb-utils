#!/bin/bash

IMAGE_FNAME="utils/lib/wb-usb-otg/mass_storage.img"
BS_K="512K"
CONTENTS_DIR="utils/lib/wb-usb-otg/mass_storage_contents"

set -e

size=$(du --block-size=$BS_K -s $CONTENTS_DIR/ | awk '{print $1}')
size=$((size+1))
echo "Creating $IMAGE_FNAME $size*$BS_K"
dd if=/dev/zero of=$IMAGE_FNAME bs=$BS_K seek=$size count=0

mformat -i $IMAGE_FNAME
mcopy -i $IMAGE_FNAME $CONTENTS_DIR/* ::
