#!/bin/bash
# This module performs conversion from DT values to Wirenboard's
# backward-compatible (ehh, almost) environment vars set.

wb_of_parse_version() {
	local version
	local varname="WB_VERSION"

	for compat in $(of_node_compatible /); do
		case "$compat" in
		contactless,*wirenboard*)
			version=`echo "$compat" | sed 's/contactless,.*wirenboard-\?\(.*\)$/\1/'`
			break
			;;
		wirenboard,*wirenboard*)
			version=`echo "$compat" | sed 's/wirenboard,.*wirenboard-\?\(.*\)$/\1/'`
			break
			;;
		esac
	done

	[[ -n "$version" ]] && echo "export ${varname}=$(to_upper_snake "$version")"
}

wb_gpio_to_vars() {
	[[ "$#" != 3 ]] && die "Wrong invocation"
	local prefix=$1
	local name="$(to_upper_snake "$2")"
	local gpio=$3

	echo "export ${prefix}_${name}=$(of_gpio_to_num "$gpio")"
	if of_gpio_is_inverted "$gpio"; then
		echo "export ${prefix}_${name}_INVERTED=1"
	fi
}

wb_of_parse_gpios() {
	local subnode=$1
	local node="${WB_OF_ROOT}/$subnode"
	local prefix="WB_GPIO"
	[[ "$subnode" != "gpios" ]] && prefix+="_$(to_upper_snake "$subnode")"

	for gpioname in  $(of_node_children "$node"); do
		wb_gpio_to_vars "$prefix" "$gpioname" \
			"$(of_get_prop_gpio "$node/$gpioname" "io-gpios")"
		# TODO: export boolean properties like 'input', 'output-low' etc.
	done
}

wb_of_parse_gpios_props() {
	local subnode="$1"
	local node="${WB_OF_ROOT}/$subnode"
	local prefix="WB_GPIO"

	[[ -z $2 ]] && subnode_prefix="$(to_upper_snake "$subnode")" || subnode_prefix="$(to_upper_snake "$2")"

	[[ "$subnode" != "gpios" ]] && prefix+="_$subnode_prefix"

	for gpioname in $(of_node_props "$node" | sed -n 's/-gpios$//p'); do
		wb_gpio_to_vars "$prefix" "$gpioname" \
			"$(of_get_prop_gpio "$node" "$gpioname-gpios")"
	done
}

wb_of_parse_props() {
	local subnode="$1"
	local node="${WB_OF_ROOT}/$subnode"
	local prefix="WB"
	[[ -n "$subnode" ]] && prefix+="_$(to_upper_snake "$subnode")"

	for prop in $(of_node_props "$node"); do
		name="$(to_upper_snake "$prop")"
		echo "export ${prefix}_${name}=\"$(of_get_prop_auto "$node" "$prop")\""
	done
}

wb_of_parse() {
	debug "Parsing hardware-specific environment from OF"
	# Associative array for GPIO phandle to gpiochip resolving
	declare -A OF_GPIOCHIPS
	declare -A OF_GPIOCHIPS_NCELLS
	of_find_gpiochips

	declare -p OF_GPIOCHIPS

	wb_of_parse_props

	of_node_exists "${WB_OF_ROOT}/gpios" && wb_of_parse_gpios gpios || \
        echo "# No enabled GPIOs node found"

	# USB is new default modem's connection => required gpios are defined in actual usb node (instead of wirenboard/gsm)
	of_node_exists "aliases/wbc_modem" && usb_of_node=$(of_get_prop_str "aliases" "wbc_modem") || usb_of_node=""
	subnode_envvar_prefix="GSM"
	for node in $usb_of_node "${WB_OF_ROOT}/gsm"; do
		of_node_exists $node && {
			echo "export WB_GSM_POWER_TYPE=$(of_get_prop_ulong $node power-type)"
			WB_OF_ROOT=""
			wb_of_parse_gpios_props $node $subnode_envvar_prefix
			break
		} || echo "# No enabled node $node found"
	done

	of_node_exists "${WB_OF_ROOT}/radio" && {
		tmp="$(of_get_prop_ulong ${WB_OF_ROOT}/radio spi-major-minor | split_each 1)"
		echo "export WB_RFM_SPI_MAJOR=$(index 0 <<< "$tmp")"
		echo "export WB_RFM_SPI_MINOR=$(index 1 <<< "$tmp")"
		wb_of_parse_gpios_props radio

		#For compatibility with legacy variable name
		echo "export WB_GPIO_RFM_IRQ=\$WB_GPIO_RADIO_IRQ"
	} || echo "# No enabled radio node found"
}
