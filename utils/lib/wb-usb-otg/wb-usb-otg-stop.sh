#!/bin/bash

DEVDIR=/sys/kernel/config/usb_gadget/g1
PID_FILE=/var/run/wb-usb-otg.pid

log_target() {
    if [ -z "$1" ]; then
        level=info
    else
        level=$1
    fi
    exec systemd-cat -t wb-usb-otg -p $level    
}

log() {
    echo $1
    echo $1 | log_target $2
}

log "wb-usb-otg-stop"

if [ -f $PID_FILE ]; then
    log "Start script seems to be running, killing"
    pkill -F $PID_FILE
    rm $PID_FILE
fi

if [ -d $DEVDIR ]; then
    log "Gadget detected, stopping"
else
    log "Gadget not detected, exiting"
    exit
fi

echo '' > $DEVDIR/UDC | log_target

[ -L $DEVDIR/os_desc/c.1 ] && rm $DEVDIR/os_desc/c.1 | log_target

log "Removing strings from configurations"
for dir in $DEVDIR/configs/*/strings/*; do
    [ -d $dir ] && rmdir $dir | log_target
done

log "Removing functions from configurations"
for func in $DEVDIR/configs/*.*/*.*; do
    [ -e $func ] && rm $func | log_target
done

log "Removing configurations"
for conf in $DEVDIR/configs/*; do
    [ -d $conf ] && rmdir $conf | log_target
done

log "Removing functions"
for func in $DEVDIR/functions/*.*; do
    [ -d $func ] && rmdir $func | log_target
done

log "Removing strings"
for str in $DEVDIR/strings/*; do
    [ -d $str ] && rmdir $str | log_target
done

log "Removing gadget"
rmdir $DEVDIR | log_target
