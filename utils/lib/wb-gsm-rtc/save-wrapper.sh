#!/bin/bash

set -e

# FIXME: replace this with save-condition.sh after transition to bullseye (task #40722)

# FIXME: replace with more suitable check
if ! /usr/bin/wb-gsm-rtc present; then
    echo "No modem present; nothing to do"
    exit 0
fi

# save time only if it's already year 2001
if [ "$(date +%s)" -ge 978307200 ]; then
    /usr/bin/wb-gsm-rtc save_time
else
    echo "Refuse to save incorrect date"
fi
