#!/bin/bash
### BEGIN INIT INFO
# Provides:          wb-init
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Required-Start: $remote_fs ntp
# Required-Stop:
# Short-Description:  board-specific initscript
# Description:        board-specific initscript
### END INIT INFO

# Do NOT "set -e"

# PATH should only include /usr/* if it runs after the mountnfs.sh script
PATH=/sbin:/usr/sbin:/bin:/usr/bin
DESC="board-specific initscript"
NAME=wb-init
#~ BIN_NAME=/usr/bin/$NAME
#~ DAEMON=$BIN_NAME
#~ PIDFILE=/var/run/$NAME.pid
SCRIPTNAME=/etc/init.d/$NAME
# Exit if the package is not installed
#~ [ -x "$DAEMON" ] || exit 0

#~ # Read configuration variable file if it is present
#~ [ -r /etc/default/$NAME ] && . /etc/default/$NAME

# Load the VERBOSE setting and other rcS variables
. /lib/init/vars.sh

VERBOSE="yes"

# Define LSB log_* functions.
# Depend on lsb-base (>= 3.2-14) to ensure that this file is present
# and status_of_proc is working.
. /lib/lsb/init-functions

#
# Function that starts the daemon/service
#

. /etc/wb_env.sh
wb_source "hardware"
wb_source "of"

do_start()
{
	# Return
	#   0 if daemon has been started
	#   1 if daemon was already running
	#   2 if daemon could not be started

    if of_machine_match "contactless,imx6ul-wirenboard60" || of_machine_match "contactless,imx28-wirenboard50"; then
        #  blink green led
        led_blink green
        led_off red
        
        gpio_setup "${WB_GPIO_5V_OUT}" high

    elif of_machine_match "contactless,imx28-wirenboard50"; then
        # reset RTS state on RS-485 transcievers
        stty -F /dev/ttyAPP1 > /dev/null
        stty -F /dev/ttyAPP2 > /dev/null
        stty -F /dev/ttyAPP3 > /dev/null
        stty -F /dev/ttyAPP4 > /dev/null

    elif of_machine_match "contactless,imx23-wirenboard41"; then
        #  switch on green led
        led_off red
        led_on green

    elif of_machine_match "contactless,imx23-wirenboard-kmon1"; then
        gpio_setup "${WB_GPIO_5V_ISOLATED_ON}" high
    fi
    
    fw_setenv bootcount 0
    fw_setenv upgrade_available 0

    return 0
}

#
# Function that stops the daemon/service
#
do_stop()
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
	[ "$VERBOSE" != no ] && log_daemon_msg "Starting $DESC" "$NAME"
	do_start
	case "$?" in
		0|1) [ "$VERBOSE" != no ] && log_end_msg 0 ;;
		2) [ "$VERBOSE" != no ] && log_end_msg 1 ;;
	esac
	;;
  stop)
	[ "$VERBOSE" != no ] && log_daemon_msg "Stopping $DESC" "$NAME"
	do_stop
	case "$?" in
		0|1) [ "$VERBOSE" != no ] && log_end_msg 0 ;;
		2) [ "$VERBOSE" != no ] && log_end_msg 1 ;;
	esac
	;;
  status)
	 exit 0;
	;;


  *)
	echo "Usage: $SCRIPTNAME {start|stop|status}" >&2
	exit 3
	;;
esac

:
