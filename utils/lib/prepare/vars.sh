# Some constants that are useful for preparing and updating Wiren Board device
# Moved here from wb-prepare script
#
# Copyright (c) 2018 Contactless Devices LLC

# Main storage device name (EMMC)
WB_STORAGE=/dev/mmcblk0

# rootfs partition size (in megabytes and in bytes)
WB_ROOTFS_SIZE_MB=1024
WB_ROOTFS_SIZE_BYTES=$[${WB_ROOTFS_SIZE_MB}*1024*1024]

# begginning of first partition in sectors (default value in case if 
# partition table is broken)
WB_FIRSTPART_START=2048

# block device sector size
WB_SECTOR_SIZE=512
