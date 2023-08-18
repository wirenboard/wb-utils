#!/bin/bash

[[ "$LC_TERMINAL" = "wb-ts" ]] && return 0

# unset all old variables with WB_ prefix beforehand
for var in "${!WB_@}"; do unset "$var"; done

source "/usr/lib/wb-utils/common.sh"

export WB_ENV_CACHE="${WB_ENV_CACHE:-/var/run/wb_env.cache}"

if /usr/lib/wb-utils/ensure-env-cache.sh; then
    set -a
    source "$WB_ENV_CACHE"
    set +a
else
    echo "Failed to generate wb_env cache in $WB_ENV_CACHE"
fi
