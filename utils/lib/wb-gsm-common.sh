#!/bin/bash

. /usr/lib/wb-utils/wb_env.sh
wb_source "hardware"
wb_source "of"

DEFAULT_BAUDRATE=115200
PORT=/dev/ttyGSM
USB_SYMLINK_MASK="/dev/ttyGSM"

OF_GSM_NODE="wirenboard/gsm"  # deprecated since default modem's connection is usb


function guess_of_node() {
    # default modem's connection is usb (with modem node on specific port)
    # wirenboard/gsm node is left for uart-only-modems compatibility
    of_has_prop "aliases" "wbc_modem" && OF_GSM_NODE=$(of_get_prop_str "aliases" "wbc_modem") || OF_GSM_NODE="wirenboard/gsm"
    debug "Got of_gsm_node: $OF_GSM_NODE"
}


function has_usb() {
    # usually modems have UART for AT-commands and USB-uart for data connection
    # probing and symlinking appropriate USB-AT ports if modem has usb
    local compatible_str="wirenboard,wbc-usb"
    of_node_exists $OF_GSM_NODE && of_node_match $OF_GSM_NODE $compatible_str &>/dev/null
}


function is_at_over_usb() {
    # at-communications inside wb-gsm could be performed via uart or usb
    # we could communicate via uart, while probing and symlinking usb ports (if present in modem)
    has_usb  # communicating via usb by default
}


function is_model() {
    local ret
    local model_to_search=$1

    if of_has_prop $OF_GSM_NODE "model"; then
        ret=$(of_get_prop_str $OF_GSM_NODE "model")
    else
        debug "Missing prop 'model' in modem dtso"
    fi

    [[ $ret == $model_to_search ]]
}


function do_exit() {
    kill -s TERM $WB_GSM_PID
    exit 1
}


function force_exit() {
    # exitting (to where the trap to TERM signal placed) from any inner-func (with turning GSM_POWER off if available)
    # default trap to ERR waits a caller to finish, which sometimes is not suitable
    if [[ -n "$OF_GSM_NODE" ]]; then
        if of_has_prop $OF_GSM_NODE "power-gpios"; then
            >&2 echo "Turning OFF modem's POWER FET"
            gpio_set_value $(of_get_prop_gpionum $OF_GSM_NODE "power-gpios") 0
        fi
    fi

    >&2 echo "Force exit: $@"
    for (( i = 1; i < ${#FUNCNAME[@]} - 1; i++ )); do
        >&2 echo " $i: ${BASH_SOURCE[$i+1]}:${BASH_LINENO[$i]} ${FUNCNAME[$i]}(...)"
    done
    do_exit
}

function force_exit_handler() {
    has_usb && unlink_ports
    exit 1
}


function check_is_not_driven_by_mm() {
    # New wb gsm modems (wbc-4g) are supported in NetworkManager + ModemManager => wb-gsm actions are forbidden
    # Whether modem is supported in MM or not is defined via udev rules by vid/pid
    if systemctl is-active --quiet ModemManager; then
        mmcli -S &> /dev/null
        if mmcli -L | grep -q '/org/freedesktop/ModemManager'; then
            >&2 echo "Modem is driven by ModemManager; exiting with rc: 1"
            do_exit
        fi
    fi
}


function get_modem_usb_devices() {
    # usb-port, modem connected to, is binded in device-tree
    # returns all tty devices on this port
    local compatible_str="wirenboard,wbc-usb"

    for device in $(ls -d /sys/bus/usb/devices/*/of_node); do
        if of_node_match $(readlink -f $device) $compatible_str &>/dev/null; then
            usb_root=$(echo $device | sed 's/of_node//')
            break
        fi
    done
    [[ -z $usb_root ]] && echo $usb_root || echo $(ls -R $usb_root* | grep -o 'tty[a-zA-Z0-9]\+$' | sort -u)
}


function test_connection() {
    if ! /bin/fuser -s $1; then
        /usr/bin/timeout --signal=SIGKILL --preserve-status $2 /usr/sbin/chat -v   TIMEOUT $2 ABORT "ERROR" ABORT "BUSY" "" AT OK "" > $1 < $1
        RC=$?
    else
        debug "$1 is not free"
        RC=1
    fi

    debug "(port:$1; timeout:$2) => $RC"
    echo $RC
}


function probe_usb_ports() {
    # a usb-connected modem produces multiple tty devices
    # probing, which ones are AT-ports
    local assumed_ports=$(get_modem_usb_devices)
    local answered_ports=()

    debug "Probing all modem's usb ports"
    for portname in $assumed_ports; do
        port="/dev/$portname"
        [[ -c $port ]] && [[ $(test_connection $port 2) == 0 ]] && answered_ports+=( $port )
    done

    debug "Modem's usb ports: ${assumed_ports[@]}"
    debug "Answered to 'AT': ${answered_ports[@]}"
    echo ${answered_ports[@]}
}


function link_ports() {
    # Creating symlinks to known AT-ports
    # Returns a first one!
    local symlinked_ports=()
    local pos=0

    for port in "$@"; do
        symlinked_port="${USB_SYMLINK_MASK}${pos}"
        ln -sfn $port $symlinked_port && symlinked_ports+=( $symlinked_port ); let pos+=1
    done

    debug "$@ => ${symlinked_ports[@]}"

    [[ -L $PORT ]] && unlink $PORT  # /dev/ttyGSM could be already linked via udev
    ln -sfn $symlinked_ports $PORT
    debug "$symlinked_ports => $PORT"
}

function unlink_ports() {
    local unlinked_ports=()
    for port in $PORT ${USB_SYMLINK_MASK}[0-9]*; do
        if [[ -L $port ]]; then
            unlink $port && unlinked_ports+=( $port )
        fi
    done
    [[ -n $unlinked_ports ]] && debug "Unlinked: ${unlinked_ports[@]}"
}


function init_usb_connection() {
    # waiting for appropriate usb-ports appear
    # probing, which ones have answered to AT; creating symlinks
    local allowed_delay=30

    debug "Will wait up to ${allowed_delay}s untill usb port becomes available"
    for ((i=0; i<=allowed_delay; i++)); do
        if [[ -n `echo $(get_modem_usb_devices)` ]]; then
            break # appropriate usb ports are available in system
        fi
        sleep 1
    done

    if [[ -z `echo $(get_modem_usb_devices)` ]]; then
        force_exit "no usb device after ${allowed_delay}s"
    fi

    modem_at_ports=$(probe_usb_ports)

    # any of modem's usb ports answered to AT
    if [[ -n "$modem_at_ports" ]]; then

        # A76x0E modems support ppp connection only via last port
        # => should be symlinked to /dev/ttyGSM (instead a first one)
        # visit https://mt-system.ru/sites/default/files/documents/moduli_a-serii_i_open_sdk.pdf for more info
        local model_4g="a7600x"
        if is_model $model_4g; then
            debug "Got modem model $model_4g from dtso => reversing port symlinks"
            modem_at_ports=$(echo "${modem_at_ports[@]} " | tac -s " ")
        fi
        link_ports $modem_at_ports
        return 0
    fi

    force_exit "no valid usb-AT connection after ${allowed_delay}s"
}

function of_prop_required() {
    # hiding tons of debug output in of_* funcs
    # terminating wb-gsm, if required of_prop is missing
    [[ $# -ne 3 ]] && {
        force_exit "${FUNCNAME[1]} usage: <of_parsing_func> <of_node> <prop>"
    }

    local of_node=$2
    local prop=$3
    of_has_prop $of_node $prop && echo "$($@ 2>/dev/null)" || {  # of_get_prop* return 0 even if prop is missing
        force_exit "Required prop $of_node->$prop is missing!"
    }
}

function get_model() {
    set_speed
    wb-gsm restart_if_broken

    REPORT_FILE=`mktemp`
    /usr/sbin/chat -s -r $REPORT_FILE  \
        TIMEOUT 2 \
        ABORT "ERROR" \
        REPORT "\r\n" \
        "" "AT+CGMM" OK ""  > $PORT < $PORT
    RC=$?


    if [[ $RC != 0 ]] ; then
        debug "ERROR while getting modem model"
        rm $REPORT_FILE
        exit $RC;
    fi

    REPORT=`cat $REPORT_FILE | sed -n 2p | sed 's/+CGMM: //'`
    rm $REPORT_FILE

    echo "$REPORT"
}


function synchronize_baudrate() {
    if is_model "sim7000e"; then
        tries=10
        for (( i=0; i<=$tries; i++ ))
        do
    	    echo -e "AT\r\n" > $PORT
        done
    else
        echo  -e "AAAAAAAAAAAAAAAAAAAT\r\n" > $PORT
    fi
}


function is_neoway_m660a() {
    MODEL=`get_model`
    [[ "$MODEL" == "M660A" ]]
}


function gsm_present() {
    of_has_prop $OF_GSM_NODE "power-type" && [[ $(of_get_prop_ulong $OF_GSM_NODE "power-type") != "0" ]]
}

function gsm_init() {
    if ! gsm_present; then
        debug "No GSM modem present, exiting"
        exit 1
    fi

    if ! is_at_over_usb; then
        # UART is always present (even if modem is turned off)
        if [[ ! -c "$PORT" || ! -r "$PORT" || ! -w "$PORT" ]]; then
            debug "Cannot access GSM modem serial port, exiting"
            exit 1
        else
            debug "Connecting via uart; port: $PORT"
            set_speed
        fi
    fi

    local gpio_gsm_pwrkey=$(of_prop_required of_get_prop_gpionum $OF_GSM_NODE "pwrkey-gpios")
    local gsm_power_type=$(of_prop_required of_get_prop_ulong $OF_GSM_NODE "power-type")
    local gpio_gsm_power=$(of_prop_required of_get_prop_gpionum $OF_GSM_NODE "power-gpios")
    local gpio_gsm_status=$(of_prop_required of_get_prop_gpionum $OF_GSM_NODE "status-gpios")

    gpio_setup $gpio_gsm_pwrkey out

    if [[ $gsm_power_type = "1" ]]; then
        local gpio_gsm_reset=$(of_prop_required of_get_prop_gpionum $OF_GSM_NODE "reset-gpios")
        gpio_setup $gpio_gsm_reset low
    fi

    if [[ $gsm_power_type = "2" ]]; then
        gpio_setup $gpio_gsm_power out
    fi

    if [[ -n $gpio_gsm_status ]]; then
        gpio_setup $gpio_gsm_status in
        if of_gpio_is_inverted $(of_prop_required of_get_prop_gpio $OF_GSM_NODE "status-gpios"); then
            gpio_set_inverted $gpio_gsm_status 1
        else
            gpio_set_inverted $gpio_gsm_status 0
        fi
    fi

    if of_has_prop $OF_GSM_NODE "simselect-gpios"; then  # some wb5's modems have not simselect
        local gpio_gsm_simselect=$(of_prop_required of_get_prop_gpionum $OF_GSM_NODE "simselect-gpios")
        if [[ ! -e "$(gpio_attr_path "$gpio_gsm_simselect")" ]]; then
            gpio_export $gpio_gsm_simselect
            gpio_set_dir $gpio_gsm_simselect out
            local simselect_val=0  # SIM1 is active
            gpio_set_value $gpio_gsm_simselect $simselect_val
            debug "Exported and toggled SIMSELECT (gpio$gpio_gsm_simselect -> $simselect_val)"
        fi
    fi

    check_is_not_driven_by_mm

    if has_usb; then
        if [[ `gpio_get_value $gpio_gsm_status` -eq "1" ]]; then
            debug "USB modem is turned on already; probing ($PORT, ${USB_SYMLINK_MASK}*) ports"
            for port in $PORT ${USB_SYMLINK_MASK}[0-9]*; do
                [[ -c $port ]] && [[ $(test_connection $port 2) == 0 ]] && {
                    debug "\$PORT (for internal communications) => $port"
                    PORT=$port
                    return 0
                }
            done
            debug "Modem is connected via USB, but no valid ports are present. Reinitializing USB connection"
            init_usb_connection
        fi
    fi
}


function toggle() {
    local gsm_power_type=$(of_prop_required of_get_prop_ulong $OF_GSM_NODE "power-type")
    local gpio_gsm_power=$(of_prop_required of_get_prop_gpionum $OF_GSM_NODE "power-gpios")
    local gpio_gsm_pwrkey=$(of_prop_required of_get_prop_gpionum $OF_GSM_NODE "pwrkey-gpios")

    debug "toggle GSM modem state using PWRKEY"

    if [[ $gsm_power_type = "2" ]]; then
        gpio_set_value $gpio_gsm_power 1
    fi

    sleep 1
    gpio_set_value $gpio_gsm_pwrkey 0
    sleep 1
    gpio_set_value $gpio_gsm_pwrkey 1
    sleep 1
    gpio_set_value $gpio_gsm_pwrkey 0
}

function reset() {
    local gsm_power_type=$(of_prop_required of_get_prop_ulong $OF_GSM_NODE "power-type")
    local gpio_gsm_power=$(of_prop_required of_get_prop_gpionum $OF_GSM_NODE "power-gpios")

    if [[ $gsm_power_type = "1" ]]; then
        debug "Resetting GSM modem using RESET pin"
        local gpio_gsm_reset=$(of_prop_required of_get_prop_gpionum $OF_GSM_NODE "reset-gpios")
        gpio_set_value $gpio_gsm_reset 1
        sleep 0.5
        gpio_set_value $gpio_gsm_reset 0
        sleep 0.5
    fi

    if [[ $gsm_power_type = "2" ]]; then
        debug "Resetting GSM modem using POWER FET"
        gpio_set_value $gpio_gsm_power 0
        sleep 0.5
        gpio_set_value $gpio_gsm_power 1
        sleep 0.5
    fi

}

function set_speed() {
    if [[ -z "$1" ]]; then
        BAUDRATE=${DEFAULT_BAUDRATE}
    else
        BAUDRATE=$1
    fi

    if ! is_at_over_usb; then
        stty -F $PORT ${BAUDRATE} cs8 -cstopb -parenb -icrnl
    fi  # In usb-connection case, setting BD is mock; actual port's BD is a modem's one
}

function _try_set_baud() {
    local RC=1
    if [[ $(test_connection $PORT 5) == 0 ]] ; then
        debug "Got answer from modem, now set the fixed baudrate"
        echo  -e "AT+IPR=115200\r\n" > $PORT
        RC=0
    fi
    echo $RC
}

function init_baud() {
    # Sets module baudrate to fixed 115200.
    # Handles both models with auto baud rate detection (SIM9xx/SIM8xx)
    #  and models with some fixed preset speed (Neoway M660A)


    ensure_on

    # Step 1: sets default baudrate, then try to make modem to detect
    # baudrate by sending AAA bytes

    set_speed
    synchronize_baudrate

    sleep 1
    if [[ $(_try_set_baud) == 0 ]] ; then
        return
    fi

    # connection test failed...
    # Step 2: try to connect at lower speed
    set_speed 9600
    if [[ $(_try_set_baud) == 0 ]] ; then
        # connection at the lower baud rate succeded, not set the default baudrate
        set_speed
        return
    fi
    debug "ERROR: couldn't establish connection with modem"
}

function imei() {
    set_speed
    REPORT_FILE=`mktemp`
    /usr/sbin/chat -s -r $REPORT_FILE  TIMEOUT 2 ABORT "ERROR" REPORT "86" "" "AT+CGSN" OK ""  > $PORT < $PORT
    RC=$?


    if [[ $RC != 0 ]] ; then
        debug "ERROR while getting IMEI"
        rm $REPORT_FILE
        exit $RC;
    fi

    REPORT=`cat $REPORT_FILE | cut -d' ' -f6-`
    rm $REPORT_FILE

    echo $REPORT
}

function imei_sn() {
    IMEI=`imei`
    IMEI_SN=`echo $IMEI | cut -c 9-14`
    echo ${IMEI_SN}
}

function switch_off() {
    local gpio_gsm_status=$(of_prop_required of_get_prop_gpionum $OF_GSM_NODE "status-gpios")
    local gsm_power_type=$(of_prop_required of_get_prop_ulong $OF_GSM_NODE "power-type")
    local gpio_gsm_power=$(of_prop_required of_get_prop_gpionum $OF_GSM_NODE "power-gpios")

    check_is_not_driven_by_mm

    [[ -n $gpio_gsm_status ]] && [[ "`gpio_get_value $gpio_gsm_status`" = "0" ]] && {
        debug "Modem is already OFF"
        return 0
    } || debug "Modem is ON. Will try to switch off GSM modem "

    if [[ $gsm_power_type = "1" ]]; then
        debug "resetting GSM modem first"
        reset
        sleep 3
    fi

    debug "Send power down command > $PORT"
    set_speed
    echo  -e "AT+CPOWD=1\r\n" > $PORT # for SIMCOM
    echo  -e "AT+CPWROFF\r\n" > $PORT # for SIMCOM

    if [[ -n $gpio_gsm_status ]]; then
        debug "Waiting for modem to stop"
        max_tries=25

        for ((i=0; i<=upperlim; i++)); do
            if [[ "`gpio_get_value $gpio_gsm_status`" = "0" ]]; then
                break
            fi
            sleep 0.2
        done
    else
        sleep 5
    fi

    has_usb && unlink_ports

    if [[ $gsm_power_type = "2" ]]; then
        debug "physically switching off GSM modem using POWER FET"
        gpio_set_value $gpio_gsm_power 0
    fi;
}

function ensure_on() {
    local gpio_gsm_status=$(of_prop_required of_get_prop_gpionum $OF_GSM_NODE "status-gpios")
    local gsm_power_type=$(of_prop_required of_get_prop_ulong $OF_GSM_NODE "power-type")
    local gpio_gsm_power=$(of_prop_required of_get_prop_gpionum $OF_GSM_NODE "power-gpios")

    if [[ -n "$gpio_gsm_status" ]]; then
        if [[ "`gpio_get_value $gpio_gsm_status`" = "1" ]]; then
            debug "Modem is already switched on"
            return
        fi
    else
        switch_off
    fi

    if [[ $gsm_power_type = "2" ]]; then
        debug "switching on GSM modem using POWER FET"
        gpio_set_value $gpio_gsm_power 1
    fi;

    toggle

    if [[ -n "$gpio_gsm_status" ]]; then
        debug "Waiting for modem to start"
        max_tries=30

        for ((i=0; i<=max_tries; i++)); do
            if [[ "`gpio_get_value $gpio_gsm_status`" = "1" ]]; then
                break
            fi
            sleep 0.1
        done
    else
        sleep 2
    fi

    check_is_not_driven_by_mm

    if has_usb; then
        init_usb_connection
    fi

    set_speed

    # Set default baudrate, then try to make modem to detect
    # baudrate by sending AAA bytes.

    # This is needed for SIM5300E and other models that
    # reset to autobauding on each power on

    synchronize_baudrate
}


function restart_if_broken() {
    local gpio_gsm_status=$(of_prop_required of_get_prop_gpionum $OF_GSM_NODE "status-gpios")

    #~ set_speed
    local RC=0
    if [[ -n "$gpio_gsm_status" ]]; then
        if [[ "`gpio_get_value $gpio_gsm_status`" = "0" ]]; then
            debug "Modem switched off, switch it on instead of testing the connection"
            local RC=1
        fi
    fi

    if [[ $RC == 0 ]]; then
        RC=$(test_connection $PORT 5)
        if [[ $RC != 0 ]] ; then
            debug "WARNING: connection test error!"
            switch_off
        fi
    fi

    if [[ $RC != 0 ]] ; then
        ensure_on
        sleep 1

        local max_retries=10
        for ((run=1;run<$max_retries;run++)); do
            RC=$(test_connection $PORT 5)
            if [[ $RC == 0 ]]; then
                return 0;
            fi

            debug "WARNING: modem restarted, still no answer ($run/${max_retries})"
            sleep 1
        done;
        debug "ERROR: modem restarted, still no answer"
        exit $RC

    fi
}


function gsm_get_time() {
    #~ set_speed
    REPORT_FILE=`mktemp`
    /usr/sbin/chat -s -r $REPORT_FILE  TIMEOUT 2 ABORT "ERROR" REPORT "+CCLK:" "" "AT+CCLK?" OK ""  > $PORT < $PORT
    RC=$?

    if [[ $RC != 0 ]] ; then
        debug "ERROR while getting time"
        rm $REPORT_FILE
        exit $RC;
    fi

    REPORT=`cat $REPORT_FILE | cut -d' ' -f6-`
    rm $REPORT_FILE

    TIME="${REPORT:8:17}"
    echo $TIME
}


function gsm_set_time() {

    if is_neoway_m660a; then
        TIMESTR="$1";
    else
        TIMESTR="$1+00"
    fi


    REPORT_FILE=`mktemp`
    /usr/sbin/chat -s  TIMEOUT 2 ABORT "ERROR" REPORT "OK" "" "AT+CCLK=\"$TIMESTR\"" OK ""  > $PORT < $PORT
    RC=$?

    if [[ $RC != 0 ]] ; then
        debug "ERROR while setting time"
        exit $RC;
    fi
}


# WB NetworkManager + ModemManager (NM+MM) only
function mm_gsm_init() {
    if ! has_usb; then
        debug "No GSM modem present"
        exit 1
    fi

    local gpio_gsm_pwrkey=$(of_prop_required of_get_prop_gpionum $OF_GSM_NODE "pwrkey-gpios")
    local gsm_power_type=$(of_prop_required of_get_prop_ulong $OF_GSM_NODE "power-type")
    local gpio_gsm_power=$(of_prop_required of_get_prop_gpionum $OF_GSM_NODE "power-gpios")
    local gpio_gsm_status=$(of_prop_required of_get_prop_gpionum $OF_GSM_NODE "status-gpios")

    if [[ $gsm_power_type != "2" ]]; then
        debug "Unsupported GSM modem power_type"
        exit 1
    fi

    if [[ -z $gpio_gsm_status ]]; then
        debug "GSM status GPIO is not defined"
        exit 1
    fi

    gpio_setup $gpio_gsm_pwrkey out
    gpio_setup $gpio_gsm_power out
    gpio_setup $gpio_gsm_status in

    if of_gpio_is_inverted $(of_prop_required of_get_prop_gpio $OF_GSM_NODE "status-gpios"); then
        gpio_set_inverted $gpio_gsm_status 1
    else
        gpio_set_inverted $gpio_gsm_status 0
    fi
}

# Only toggling power & pwrkey gpios
function mm_on() {
    mm_gsm_init

    local gpio_gsm_status=$(of_prop_required of_get_prop_gpionum $OF_GSM_NODE "status-gpios")
    local gpio_gsm_power=$(of_prop_required of_get_prop_gpionum $OF_GSM_NODE "power-gpios")
    local gpio_gsm_pwrkey=$(of_prop_required of_get_prop_gpionum $OF_GSM_NODE "pwrkey-gpios")

    if [[ "`gpio_get_value $gpio_gsm_status`" = "1" ]]; then
        debug "Modem is already switched on"
        return 0
    fi

    gpio_set_value $gpio_gsm_power 1
    sleep 1
    gpio_set_value $gpio_gsm_pwrkey 0
    sleep 1
    gpio_set_value $gpio_gsm_pwrkey 1
    sleep 1
    gpio_set_value $gpio_gsm_pwrkey 0
    sleep 9

    debug "Waiting for modem to start"
    max_tries=40
    for ((i=0; i<=max_tries; i++)); do
        if [[ "`gpio_get_value $gpio_gsm_status`" = "1" ]]; then
            break
        fi
        sleep 0.5
    done
}

# Only toggling power & pwrkey gpios
function mm_off() {
    mm_gsm_init

    local gpio_gsm_status=$(of_prop_required of_get_prop_gpionum $OF_GSM_NODE "status-gpios")
    local gpio_gsm_power=$(of_prop_required of_get_prop_gpionum $OF_GSM_NODE "power-gpios")
    local gpio_gsm_pwrkey=$(of_prop_required of_get_prop_gpionum $OF_GSM_NODE "pwrkey-gpios")

    if [[ "`gpio_get_value $gpio_gsm_status`" = "0" ]]; then
        debug "Modem is already OFF"
        return 0
    else
        debug "Modem is ON. Will try to switch off GSM modem "
    fi

    gpio_set_value $gpio_gsm_pwrkey 0
    sleep 1
    gpio_set_value $gpio_gsm_pwrkey 1
    sleep 3
    gpio_set_value $gpio_gsm_pwrkey 0
    sleep 9

    debug "Waiting for modem to stop"
    max_tries=25
    for ((i=0; i<=max_tries; i++)); do
        if [[ "`gpio_get_value $gpio_gsm_status`" = "0" ]]; then
            debug "Modem is OFF"
            break
        fi
        sleep 0.2
    done

    debug "Physically switching off GSM modem using POWER FET"
    gpio_set_value $gpio_gsm_power 0
}

# WB NM+MM stack supports only wbc-4g modems (a7600x model)
function should_enable() {
    if has_usb; then
        if is_model "a7600x"; then
            debug "Should enable GSM modem"
            return 0
        else
            debug "Modem is not supported in WB NM+MM stack"
        fi
    else
        debug "No GSM modem present"
    fi
    exit 1
}
