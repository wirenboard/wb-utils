#!/bin/bash

set -e

# FIXME: replace this with restore-condition.sh after transition to bullseye (task #40722)

# FIXME: replace with more suitable check
if ! /usr/bin/wb-gsm-rtc present; then
    echo "No modem present; nothing to do"
    exit 0
fi

# restore time only if we're still in 1970's
if [ "$(date +%s)" -le 31536000 ]; then
    /usr/bin/wb-gsm-rtc restore_time
else
    echo "Date is correct already; nothing to do"
fi
