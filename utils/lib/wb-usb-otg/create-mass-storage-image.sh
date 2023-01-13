#!/bin/bash

IMAGE_FNAME="utils/lib/wb-usb-otg/mass_storage.img"
BS="512"
CONTENTS_DIR="utils/lib/wb-usb-otg/mass_storage_contents"

set -e

size=$(du --block-size=$BS -s $CONTENTS_DIR/ | awk '{print $1}')
size=$((size+1))
echo "Creating $IMAGE_FNAME $size*$BS"
dd if=/dev/zero of=$IMAGE_FNAME bs=$BS seek=$size count=0

mformat -i $IMAGE_FNAME
mcopy -i $IMAGE_FNAME $CONTENTS_DIR/* ::
