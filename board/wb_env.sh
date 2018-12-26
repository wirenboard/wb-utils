#!/bin/bash

source "/usr/lib/wb-utils/common.sh"

WB_ENV_CACHE="${WB_ENV_CACHE:-/var/run/wb_env.cache}"

WB_OF_ROOT="/wirenboard"

if [[ ! -e "$WB_ENV_CACHE" ]]; then
	ENV_TMP=$(mktemp)

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

set -a
source "$WB_ENV_CACHE"
set +a
