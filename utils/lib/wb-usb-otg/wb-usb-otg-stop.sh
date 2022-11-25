#!/bin/bash

DEVDIR=/sys/kernel/config/usb_gadget/g1
PID_FILE=/var/run/wb-usb-otg.pid

log() {
    if [ -z "$2" ]; then
        level=info
    else
        level=$2
    fi
    echo "$1 ($level)"
    echo $1 | exec systemd-cat -t wb-usb-otg -p $level
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

echo '' > $DEVDIR/UDC

[ -L $DEVDIR/os_desc/c.1 ] && rm $DEVDIR/os_desc/c.1

log "Removing strings from configurations"
for dir in $DEVDIR/configs/*/strings/*; do
    [ -d $dir ] && rmdir $dir >> $LOG_FILE 2>&1
done

log "Removing functions from configurations"
for func in $DEVDIR/configs/*.*/*.*; do
    [ -e $func ] && rm $func >> $LOG_FILE 2>&1
done

log "Removing configurations"
for conf in $DEVDIR/configs/*; do
    [ -d $conf ] && rmdir $conf >> $LOG_FILE 2>&1
done

log "Removing functions"
for func in $DEVDIR/functions/*.*; do
    [ -d $func ] && rmdir $func >> $LOG_FILE 2>&1
done

log "Removing strings"
for str in $DEVDIR/strings/*; do
    [ -d $str ] && rmdir $str >> $LOG_FILE 2>&1
done

log "Removing gadget"
rmdir $DEVDIR >> $LOG_FILE 2>&1