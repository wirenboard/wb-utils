#!/bin/bash

. "/usr/lib/wb-utils/wb_env.sh"
wb_source "hardware"
wb_source "of"

wb_init()
{
    if of_machine_match "contactless,imx6ul-wirenboard60" || of_machine_match "contactless,imx28-wirenboard50"; then
        #  blink green led
        led_blink green
        led_off red

        # this GPIO may be already captured by wb-mqtt-gpio
        gpio_setup "${WB_GPIO_5V_OUT}" high

    elif of_machine_match "contactless,imx23-wirenboard41"; then
        #  switch on green led
        led_off red
        led_on green

    elif of_machine_match "contactless,imx23-wirenboard-kmon1"; then
        gpio_setup "${WB_GPIO_5V_ISOLATED_ON}" high
    fi
    
    # reset RTS state on RS-485 transcievers on Wiren Board 5
    if of_machine_match "contactless,imx28-wirenboard50"; then
        stty -F /dev/ttyAPP1 > /dev/null
        stty -F /dev/ttyAPP2 > /dev/null
        stty -F /dev/ttyAPP3 > /dev/null
        stty -F /dev/ttyAPP4 > /dev/null
    fi

    fw_setenv bootcount 0
    fw_setenv upgrade_available 0

    return 0
}

wb_deinit()
{
	# Return
	#   0 if daemon has been stopped
	#   1 if daemon was already stopped
	#   2 if daemon could not be stopped
	#   other if a failure occurred

    if of_machine_match "contactless,imx6ul-wirenboard60" || of_machine_match "contactless,imx28-wirenboard50"; then
        #  blink red led
        led_blink red
        led_off green

    elif of_machine_match "contactless,imx23-wirenboard41"; then
        #  switch on red led
        led_on red
        led_off green
    fi

    return 0;
}

case "$1" in
start)
    wb_init
    ;;
stop)
    wb_deinit
    ;;
*)
    echo "Usage: $0 start|stop"
    ;;
esac
