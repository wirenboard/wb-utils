#!/bin/bash

WB_SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
export WB_DATA_DIR=${WB_DATA_DIR:-/var/lib/wirenboard}

if [[ -z "$DEBUG" ]] && [[ -z "$JOURNALD_PREFIX" ]]; then
	debug() { :; }
else
	# of_*: functions from of.sh and wb_env_of.sh produce tons of hardware-magic output
	# because of many debug() calls inside
	# =>
	# debug_onscreen: echoing to stderr (could suppress later)
	# debug_journald: systemd-cat accepts only stdin -> grepping "of_"
	debug_onscreen() {
		>&2 echo "DEBUG: ${FUNCNAME[2]}: $*"
	}
	debug_journald() {
		echo "${FUNCNAME[2]}: $*" | grep -v "^of_.*:" | systemd-cat -t $JOURNALD_PREFIX
	}

	if [[ -n "$DEBUG" ]] && [[ -n "$JOURNALD_PREFIX" ]]; then
		set -e
		debug() {
			debug_onscreen $*
			debug_journald $*
		}
	elif [[ -n "$DEBUG" ]]; then
		set -e
		debug() {
			debug_onscreen $*
		}
	else
		debug() {
			debug_journald $*
		}
	fi
fi

die() {
	exec >&2
	local ret=$?
	set +o xtrace
	local code="${1:-1}"
	echo "Error in ${BASH_SOURCE[1]}:${BASH_LINENO[0]}. '${BASH_COMMAND}' exited with status $ret"
	# Print out the stack trace described by $function_stack
	if [[ ${#FUNCNAME[@]} -gt 2 ]]; then
		echo "Call tree:"
		for (( i = 1; i < ${#FUNCNAME[@]} - 1; i++)); do
			echo " $i: ${BASH_SOURCE[$i+1]}:${BASH_LINENO[$i]} ${FUNCNAME[$i]}(...)"
		done
	fi
	echo "Exiting with status ${code}"
	if [[ $- != *i* ]]; then
		return "${code}"
	else
		exit "${code}"
	fi
}

if [[ -n "$DEBUG" ]]; then
	trap 'die' ERR
	set -o errtrace
fi


wb_source() {
	source "$WB_SCRIPT_DIR/${1}.sh"
}

to_upper() {
	tr 'a-z' 'A-Z' <<< "$1"
}

to_upper_snake() {
	tr 'a-z-' 'A-Z_' <<<"$1"
}

# Join array to string
# Args:
# - delimiter
# - rest args are the array items
# Example: `join , 1 2 3` == "1,2,3"
join() {
	local IFS="$1"
	shift
	echo "$*"
}
