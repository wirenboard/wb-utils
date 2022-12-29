#!/bin/bash

set -e

apt-get install dosfstools

size=`du --block-size=512K -s ./contents/ | awk '{print $1}'`
size=$(($size+1))

dd if=/dev/zero of=./mass_storage bs=512K seek=$size count=0

cat <<EOT | sfdisk -L -uS ./mass_storage 
,,c
EOT

sector_size=`fdisk -lu ./mass_storage | grep "Sector size" | awk -F ' ' '{print $7}'`
partition_start=`fdisk -lu ./mass_storage | grep "/mass_storage1" | awk '{print $2}'`
offset=$(($sector_size*$partition_start))

losetup -o$offset /dev/loop0 ./mass_storage

mkdosfs /dev/loop0

mkdir -p /mnt/ms-test

mount -t vfat /dev/loop0 /mnt/ms-test

cp ./contents/* /mnt/ms-test

ls -l /mnt/ms-test

umount /mnt/ms-test
losetup -d /dev/loop0 