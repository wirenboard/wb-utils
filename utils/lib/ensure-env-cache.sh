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

if [[ -e "$WB_ENV_CACHE" ]]; then
    # Collect last modification time from /proc/device-tree/wirenboard
    # recursively and check if cache is newer
    DT_WIRENBOARD_LAST_CHANGE="$(find "/proc/device-tree/$WB_OF_ROOT" -type f -printf "%Ts\n" | sort | tail -1)"
    CACHE_LAST_CHANGE="$(stat -c"%X" "$WB_ENV_CACHE")"

    # Remove cache file if device tree was updated. It is safe to do here, we have lock
    if [[ "$DT_WIRENBOARD_LAST_CHANGE" -gt "$CACHE_LAST_CHANGE" ]]; then
        rm "$WB_ENV_CACHE" -f
    fi
fi

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
