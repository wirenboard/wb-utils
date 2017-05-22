#!/bin/bash

DT="/proc/device-tree"

debug() { :; }
[[ -n "$DEBUG" ]] && debug() {
	>&2 echo "DEBUG: $@"
}

# Converts binary data to 32bit hex words
bin2hex() {
	# This is endianness-sensitive. Works on ARM.
	od -A n -t x1 -w4 | tr -d ' '
}

# Converts binary data to 32bit hex words, N words per line
# Args:
#	words per line
bin2hex_width() {
	od -A n -t x1 -w$((4*$1)) |
	sed -r 's/ ([0-9a-f]{2}) ([0-9a-f]{2}) ([0-9a-f]{2}) ([0-9a-f]{2})/\1\2\3\4 /g'
}

# Converts number from hex to decimal
# Args:
#	hexadecimal number
hex2dec() {
	echo "$((0x${1}))"
}

# Returns Nth line of the input
# Args:
#	line number
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

# Get canonicalized node path in the filesystem
# Args:
#	node (from DT root, or full path in /sys/firmware)
dt_node_path() {
	local node="$1"

	[[ "${node#/sys/firmware}" == "$node" ]] && node="$DT/$node"
	echo "$node"
}

# Get list of node properties matching specified glob pattern
# Args
#	node
#	name glob
dt_node_props() {
	local node="$(dt_node_path "$1")"
	local name="${2:-*}"
	
	find "$node" -maxdepth 1 -type f -name "$name" -printf '%f\n'
}

# Get raw value of property
# Args:
#	node
#	property
dt_get_prop() {
	local node="$(dt_node_path "$1")"
	local prop="$2"
	
	cat "$node/$prop"
}

# Get hex value of property, one 32bit word per line
# Args:
#	node
#	property
dt_get_prop_hex() {
	dt_get_prop "$1" "$2" | bin2hex
}

# Get unsigned int value of property, one value per line
# Args:
#	node
#	property
dt_get_prop_int() {
	local x

	dt_get_prop_hex "$1" "$2" | while read x; do
		hex2dec "$x"
	done
}

# Get string value of property, one string per line
# Args:
#	node
#	property
dt_get_prop_str() {
	dt_get_prop "$1" "$2" | tr '\000' '\n'
}

# Get compatible list of node, one item per line
# Args:
#	node
dt_get_compatible() {
	local node="${1:-}"
	
	dt_get_prop_str "$node" compatible
}

# Associative array for GPIO phandle to gpiochip resolving
declare -A DT_GPIOCHIPS

# Get GPIO(s) property resolving phandles, one GPIO per line.
# Output line format: "/sys/class/gpio/gpiochip0 10"
# Args:
#	node
#	[optional] property, default is "gpios"
#	[optional] words per gpio, default is 3
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

# Convert "<gpiochip> <pin>" to Linux GPIO number
# Args:
#	gpiochip sysfs path (e.g. "/sys/class/gpio/gpiocip0")
#	pin number within gpiochip
gpio_to_num() {
	local chip="$1"
	local pin="$2"
	echo "$(($(cat "$chip/base")+pin))"
}

# Get GPIO property as Linux gpio number
# Args:
#	node
#	property
#	[optional] index of GPIO in multi-gpio props
dt_get_prop_gpionum() {
	local index="${3:-0}"

	gpio_to_num $(dt_get_prop_gpio "$1" "$2" | index "$index")
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
