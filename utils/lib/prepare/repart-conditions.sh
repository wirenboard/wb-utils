#!/bin/bash -e

. /usr/lib/wb-utils/prepare/vars.sh

if [[ -e ${WB_STORAGE}p3 && -e ${WB_STORAGE}p5 && -e ${WB_STORAGE}p6 ]]; then
    echo "Partition table is good already"
    exit 1
else
    echo "Bad partition table! Going emergency..."
    exit 255  # systemd treats as failure
fi
