#!/bin/bash

bin2ulong() {
	local -a bytes

	od -A n -t u1 |
	split_each 4 | {
		local -a ulongs
		while read -r -a bytes; do
			ulongs+=("$((bytes[0]<<24 | bytes[1]<<16 | bytes[2]<<8 | bytes[3]))");
		done;
		echo "${ulongs[@]}"
	}
}

# Returns Nth line of the input
# Args:
#	line number
index() {
	local n="$1"
	local i=0

	# instead of using head & tail, iterate in pure bash to avoid fork/exec
	while read -r x; do
		[[ "$i" == "$n" ]] && {
			echo "$x"
			break
		}
		((i++))
	done
}

# Splits space-separated input into lines with specified amount of words per line
# Args:
#	words per line
split_each() {
	sed -r 's/((\w+\s+){'"$1"'})/\1\n/g'
}

if [[ -z "$DTB" ]]; then  ######################################################
# Get data from live device tree

# Get canonicalized node path in the filesystem
# Args:
#	node (from DT root, or full path in /sys/firmware)
__of_node_path() {
	local node="$1"

	[[ "${node#/sys/firmware}" == "$node" ]] && node="/proc/device-tree/$node"
	readlink -f "$node"
}

# Get raw value of property
# Args:
#	node
#	property
__of_get_prop() {
	local node="$(__of_node_path "$1")"
	local prop="$2"
	
	cat "$node/$prop"
}

# Checks if a given node is existing
# Args:
#	node
of_node_exists() {
	[[ -e "$(__of_node_path "$1")" ]]
}

# Get list of node's direct children
# Args:
#	node
of_node_children() {
	local node="$(__of_node_path "$1")"

	find "$node" -maxdepth 1 -type d -printf '%f\n'
}

# Get list of node properties matching specified glob pattern
# Args
#	node
#	name glob
of_node_props() {
	local node="$(__of_node_path "$1")"
	
	find "$node" -maxdepth 1 -type f -printf '%f\n'
}

# Get int value of property
# Args:
#	node
#	property
of_get_prop_ulong() {
	__of_get_prop "$1" "$2" | bin2ulong
}

# Get string value of property
# Args:
#	node
#	property
of_get_prop_str() {
	__of_get_prop "$1" "$2" | tr '\000' ' '
}

# If running on a live system, get gpiochip phandles directly from sysfs
# There can be gpiochips added on top of base DTB with overlays

of_find_gpiochips() {
	for gpiochip in /sys/class/gpio/gpiochip*; do
		phandle=$(bin2ulong < "$gpiochip/device/of_node/phandle")
		OF_GPIOCHIPS[$phandle]="$(cat "$gpiochip/base")"
	done
}

else  ##########################################################################
# Get data from specified DTB file

of_node_props() {
	fdtget -p "$DTB" "$1" 2>/dev/null
}

of_node_children() {
	fdtget -l "$DTB" "$1" 2>/dev/null
}

of_node_exists() {
	of_node_props "$1" >/dev/null
}

of_get_prop_ulong() {
	fdtget -t u "$DTB" "$1" "$2"
}

of_get_prop_str() {
	fdtget -t s "$DTB" "$1" "$2"
}

of_find_gpiochips() {
	local n=0
	for gpiochip in $(of_node_props /aliases | grep gpio); do
		node="$(of_get_prop_str /aliases "$gpiochip")"
		phandle=$(of_get_prop_ulong "$node" phandle)
		base=$((n*32))
		((n++))
		debug "Found gpiochip node $node phandle $phandle (base $base)"
		OF_GPIOCHIPS[$phandle]="$base"
	done
}
fi #############################################################################

# Get compatible list of node, one item per line
# Args:
#	node
of_node_compatible() {
	local node="${1:-}"
	
	of_get_prop_str "$node" compatible
}

of_machine_is_compatible() {
	local re="( |^)${1}( |$)"
	[[ $(of_node_compatible /) =~ $re ]]
}

# Args:
#	GPIO in "<base>:<pin>:<attr>" format
#	var names (at least one)
of_gpio_unpack() {
	[[ "$#" -ge 2 ]] || die "Bad invocation"
	local gpio=$1
	local vbase=$2 vpin=${3:-dummy} vattr=${4:-dummy}
	local dummy
	local IFS=:
	eval "read $vbase $vpin $vattr <<< \"\$gpio\""
}

# Get GPIO(s) property resolving phandles to gpiochip base, one GPIO per line.
# Output line format: "<base>:<pin>:<flags>"
# Args:
#	node
#	[optional] property, default is "gpios"
#	[optional] words per gpio, default is 3
of_get_prop_gpio() {
	debug "$@"
	local node="$1"
	local prop="${2:-gpios}"
	local cells="${3:-3}"

	of_get_prop_ulong "$node" "$prop" | split_each "$cells" |
	while read -r phandle pin attr; do
		echo "${OF_GPIOCHIPS[$phandle]}:${pin}:${attr}"
		debug "gpio $phandle $pin $attr"
	done
}

# Convert from OF form to Linux GPIO number
# Args:
#	gpio in form "<base>:<pin>[:<attr>]"
of_gpio_to_num() {
	local base pin
	of_gpio_unpack "$1" base pin
	debug "Unpacked gpio $1 -> $base+$pin"
	echo "$((base+pin))"
}

of_gpio_attr() {
	local dummy attr
	of_gpio_unpack "$1" dummy dummy attr
	echo "$attr"
}

of_gpio_is_inverted() {
	[[ "$(of_gpio_attr "$1")" == "1" ]]
}

# Get GPIO property as Linux gpio number
# Args:
#	node
#	property
#	[optional] index of GPIO in multi-gpio props
of_get_prop_gpionum() {
	local index="${3:-0}"

	of_gpio_to_num $(of_get_prop_gpio "$1" "$2" | index "$index")
}

