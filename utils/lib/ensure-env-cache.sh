#!/bin/bash

WB_ENV_CACHE="${WB_ENV_CACHE:-/var/run/wb_env.cache}"
WB_OF_ROOT="/wirenboard"

WB_ENV_LOCK="${WB_ENV_LOCK:-/var/run/wb_env.lock}"
LOCK_TIMEOUT=180

# create lockfile on descriptor 100 to make only one instance of wb_env.sh generate cache
exec 100>"$WB_ENV_LOCK" || {
    echo "Failed to create lockfile $WB_ENV_LOCK, something is really wrong"
    exit 1
}

flock -w "$LOCK_TIMEOUT" 100 || {
    echo "Failed to obtain lockfile in $LOCK_TIMEOUT s, something is really wrong"
    exit 1
}

trap 'rm -f $WB_ENV_LOCK' EXIT

if [[ ! -e "$WB_ENV_CACHE" ]]; then
	ENV_TMP=$(mktemp)

    source "/usr/lib/wb-utils/common.sh"
	wb_source "of"

	{
		if [[ -z "$FORCE_WB_VERSION" ]] && of_node_exists "${WB_OF_ROOT}"; then
			wb_source "wb_env_of" && {
				wb_of_parse_version
				wb_of_parse
			}
		else
			wb_source "wb_env_legacy"
		fi
	} > "$ENV_TMP" &&
		mv "$ENV_TMP" "$WB_ENV_CACHE"
fi
