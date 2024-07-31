#!/bin/bash

. /usr/lib/wb-utils/wb_env.sh

wb_source "of"

# wirenboard-720 matches all Wiren Board 7.x boards, that all is because of missing entry in earlier DTBs

if of_machine_match "wirenboard,wirenboard-720" || of_machine_match "wirenboard,wirenboard-8xx"; then
    exit 0
fi

exit 1
