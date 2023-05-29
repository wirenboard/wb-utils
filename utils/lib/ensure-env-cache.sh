#!/bin/bash

source "/usr/lib/wb-utils/common.sh"
wb_source "of"

WB_ENV_CACHE="${WB_ENV_CACHE:-/var/run/wb_env.cache}"
WB_OF_ROOT="/wirenboard"

WB_ENV_LOCK="${WB_ENV_LOCK:-/var/run/wb_env.lock}"
LOCK_TIMEOUT=180

WB_ENV_HASH="${WB_ENV_HASH:-/var/run/wb_env.hash}"

declare -a DT_TO_CHECK

get_hash() {
    find "$@" -type f | xargs cksum | cksum
}

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

DT_TO_CHECK=("/proc/device-tree$WB_OF_ROOT")
of_has_prop "aliases" "wbc_modem" && DT_TO_CHECK+=("/proc/device-tree$(of_get_prop_str "aliases" "wbc_modem")")

if [[ -e "$WB_ENV_CACHE" && -e "$WB_ENV_HASH" ]]; then
    actual_hash="$(get_hash "${DT_TO_CHECK[@]}")"
    stored_hash="$(cat "$WB_ENV_HASH")"

    # Remove cache file if device tree was updated. It is safe to do here, we have lock
    if [[ "$actual_hash" != "$stored_hash" ]]; then
        rm "$WB_ENV_CACHE" -f
    fi
fi

# Fill wb_env.cache & renew wb_env.hash
if [[ ! -e "$WB_ENV_CACHE" || ! -e "$WB_ENV_HASH" ]]; then
	ENV_TMP=$(mktemp)

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
		mv "$ENV_TMP" "$WB_ENV_CACHE" && get_hash "${DT_TO_CHECK[@]}" > "$WB_ENV_HASH"
fi
