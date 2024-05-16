#!/bin/bash

. /usr/lib/wb-utils/wb_env.sh

wb_source "of"

if of_machine_match "wirenboard,wirenboard-720" || of_machine_match "wirenboard,wirenboard-84x"; then
    exit 0
fi

exit 1
