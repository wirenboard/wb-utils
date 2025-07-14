. /usr/lib/wb-utils/prepare/vars.sh

wb_get_partition_start()
{
    local part=${WB_STORAGE}p$1
    fdisk -u sectors -l $WB_STORAGE |
        sed -rn "s#^${part}\\s+([0-9]+).*#\\1#p"
}
