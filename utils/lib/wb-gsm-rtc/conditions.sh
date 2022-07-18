#!/bin/bash

set -e

TS_2001=978307200
TS_1970=31536000

case "$1" in
	"save_time" )
        if ! /usr/bin/wb-gsm-rtc present; then
            echo "No modem present; nothing to do"
            exit 1
        fi

        if [ "$(date +%s)" -lt $TS_2001 ]; then
            echo "Refuse to save incorrect date"
            exit 1
        fi

        echo "Saving time to gsm modem"
	;;

	"restore_time" )
        if ! /usr/bin/wb-gsm-rtc present; then
            echo "No modem present; nothing to do"
            exit 1
        fi

        if [ "$(date +%s)" -gt $TS_1970 ]; then
            echo "Date is correct already; nothing to do"
            exit 1
        fi

        echo "Restoring time from gsm modem"
	;;

	* )
		echo "USAGE: $0 [save_time|restore_time]"
        exit 1
	;;
esac
