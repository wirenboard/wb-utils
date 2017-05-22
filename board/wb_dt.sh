#!/bin/bash

DT="/proc/device-tree"

debug() { :; }
[[ -n "$DEBUG" ]] && debug() {
	>&2 echo "DEBUG: $@"
}

bin2hex() {
	# This is endianness-sensitive. Works on ARM.
	od -A n -t x1 -w4 | tr -d ' '
}

bin2hex_width() {
	od -A n -t x1 -w$((4*$1)) |
	sed -r 's/ ([0-9a-f]{2}) ([0-9a-f]{2}) ([0-9a-f]{2}) ([0-9a-f]{2})/\1\2\3\4 /g'
}

hex2dec() {
	echo "$((0x${1}))"
}

index() {
	local n="$1"
	local i=0

	# instead of using head & tail, iterate in pure bash to avoid fork/exec
	while read x; do
		[[ "$i" == "$n" ]] && {
			echo "$x"
			break
		}
		((i++))
	done
}

dt_get_prop() {
	local node="$1"
	local prop="$2"
	
	[[ "${node#/sys/firmware}" == "$node" ]] && node="$DT/$node"
	cat "$node/$prop"
}

dt_get_prop_hex() {
	dt_get_prop "$1" "$2" | bin2hex
}

dt_get_prop_int() {
	local x

	dt_get_prop_hex "$1" "$2" | while read x; do
		hex2dec "$x"
	done
}

dt_get_prop_str() {
	dt_get_prop "$1" "$2" | tr '\000' '\n'
}

dt_get_compatible() {
	local node="${1:-}"
	
	dt_get_prop_str "$node" compatible
}

declare -A DT_GPIOCHIPS

dt_get_prop_gpio() {
	local node="$1"
	local prop="${2:-gpios}"
	local cells="${3:-3}"

	dt_get_prop "$node" "$prop" | bin2hex_width "$cells" |
	while read phandle pin attr; do
		echo "${DT_GPIOCHIPS[$phandle]} $(hex2dec ${pin})"
		debug "gpio $phandle $(hex2dec $pin) $attr"
	done
}

gpio_to_num() {
	local chip="$1"
	local pin="$2"
	echo "$(($(cat "$chip/base")+pin))"
}

dt_parse() {
	for gpiochip in /sys/class/gpio/gpiochip*; do
		phandle=$(bin2hex < "$gpiochip/device/of_node/phandle")
		DT_GPIOCHIPS[$phandle]="$gpiochip"
		debug "$(basename $gpiochip) phandle: $phandle"
	done
	unset gpiochip phandle
}

[[ -n "$DEBUG" ]] && time dt_parse
