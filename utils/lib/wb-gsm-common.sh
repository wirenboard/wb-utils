#!/bin/bash

. /usr/lib/wb-utils/wb_env.sh
wb_source "hardware"
wb_source "of"

DEFAULT_BAUDRATE=115200
PORT=/dev/ttyGSM
USB_SYMLINK_MASK="/dev/ttyWBC"

OF_GSM_NODE="wirenboard/gsm"  # deprecated since default modem's connection is usb


function has_usb() {
    # usually modems have UART for AT-commands and USB-uart for data connection
    # probing and symlinking appropriate USB-AT ports if modem has usb
    local compatible_str="wirenboard,wbc-usb"

    of_node_exists "aliases/wbc_modem" && OF_GSM_NODE=$(of_get_prop_str "aliases" "wbc_modem") || return 1
    of_node_match $OF_GSM_NODE $compatible_str &>/dev/null
}


function is_at_over_usb() {
    # at-communications inside wb-gsm could be performed via uart or usb
    # we could communicate via uart, while probing and symlinking usb ports (if present in modem)
    has_usb  # communicating via usb by default
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
    /usr/sbin/chat -v   TIMEOUT $2 ABORT "ERROR" ABORT "BUSY" "" AT OK "" > $1 < $1
    RC=$?
    debug "(port:$1; timeout:$2) => $RC"
    echo $RC
}


function probe_usb_ports() {
    # a usb-connected modem produces multiple tty devices
    # probing, which ones are AT-ports
    local answered_ports=()

    debug "Probing all modem's usb ports"
    for portname in $(get_modem_usb_devices); do
        port="/dev/$portname"
        [[ $(test_connection $port 2) == 0 ]] && answered_ports+=( $port )
    done

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
    echo $symlinked_ports  # returns first one!
}


function unlink_ports() {
    for port in $USB_SYMLINK_MASK*; do
        if [[ -L $port ]]; then
            unlink $port
            debug "Unlinked $port"
        fi
    done
}


function init_usb_connection() {
    # waiting for appropriate usb-ports appear
    # probing, which ones have answered to AT; creating symlinks
    # updating a PORT global var, if modem is connected usb-only
    local allowed_delay=30

    debug "Will wait up to ${allowed_delay}s untill usb port becomes available"
    for ((i=0; i<=allowed_delay; i++)); do
        if [[ -n `echo $(get_modem_usb_devices)` ]]; then
            break # appropriate usb ports are available in system
        fi
        sleep 1
    done

    if [[ -z `echo $(get_modem_usb_devices)` ]]; then
        debug "ERROR: no usb device after ${allowed_delay}s"
        exit 1
    fi

    modem_at_ports=$(probe_usb_ports)
    if [[ -n "$modem_at_ports" ]]; then
        # any of modem's usb ports answered to AT
        usb_at_port=`link_ports $modem_at_ports` # creating symlinks
        if is_at_over_usb; then
            PORT=$usb_at_port
            debug "Got USB-AT port: $PORT"
        fi
        return 0
    fi

    debug "ERROR: no valid usb-AT connection after ${allowed_delay}s"
    exit 1
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


function is_simcom_7000e() {
    #NB-IOT modem
    local model_to_search="sim7000e"

    if of_has_prop $OF_GSM_NODE "model"; then
        ret=$(of_get_prop_str $OF_GSM_NODE "model")
    fi

    [[ $ret == $model_to_search ]]
}


function synchronize_baudrate() {
    if is_simcom_7000e; then
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
    [[ -n "${WB_GSM_POWER_TYPE}" ]] && [[ "$WB_GSM_POWER_TYPE" != "0" ]]
}

function gsm_init() {
    if ! gsm_present; then
        debug "No GSM modem present, exiting"
        exit 1
    fi

    if ! is_at_over_usb; then
        # UART has present always (even if modem is turned off)
        if [[ ! -c "$PORT" || ! -r "$PORT" || ! -w "$PORT" ]]; then
            debug "Cannot access GSM modem serial port, exiting"
            exit 1
        else
            debug "Connecting via uart; port: $PORT"
            set_speed
        fi
    fi

    gpio_setup $WB_GPIO_GSM_PWRKEY out


    if [[ ${WB_GSM_POWER_TYPE} = "1" ]]; then
        gpio_setup $WB_GPIO_GSM_RESET low
    fi

    if [[ ${WB_GSM_POWER_TYPE} = "2" ]]; then
        gpio_setup $WB_GPIO_GSM_POWER out
    fi

    if [[ -n ${WB_GPIO_GSM_STATUS} ]]; then
        gpio_setup $WB_GPIO_GSM_STATUS in
        if [[ ${WB_GPIO_GSM_STATUS_INVERTED} = "1" ]]; then
            gpio_set_inverted $WB_GPIO_GSM_STATUS 1
        else
            gpio_set_inverted $WB_GPIO_GSM_STATUS 0
        fi
    fi

    if [[ ! -z $WB_GPIO_GSM_SIMSELECT ]]; then
        gpio_export $WB_GPIO_GSM_SIMSELECT
        gpio_set_dir $WB_GPIO_GSM_SIMSELECT out
        # select SIM1 at startup
        gpio_set_value $WB_GPIO_GSM_SIMSELECT 0
    fi

    if has_usb; then
        if [[ `gpio_get_value $WB_GPIO_GSM_STATUS` -eq "1" ]]; then
            debug "USB modem is turned on already; probing ${USB_SYMLINK_MASK}* ports"
            for port in ${USB_SYMLINK_MASK}*; do
                [[ -e $port ]] && [[ $(test_connection $port 2) == 0 ]] && {
                    PORT=$port
                    return 0
                }
            done
            init_usb_connection
        fi
    fi
}


function toggle() {
    debug "toggle GSM modem state using PWRKEY"

    if [[ ${WB_GSM_POWER_TYPE} = "2" ]]; then
        gpio_set_value $WB_GPIO_GSM_POWER 1
    fi


    sleep 1
    gpio_set_value $WB_GPIO_GSM_PWRKEY 0
    sleep 1
    gpio_set_value $WB_GPIO_GSM_PWRKEY 1
    sleep 1
    gpio_set_value $WB_GPIO_GSM_PWRKEY 0
}

function reset() {

    if [[ ${WB_GSM_POWER_TYPE} = "1" ]]; then
        debug "Resetting GSM modem using RESET pin"
        gpio_set_value $WB_GPIO_GSM_RESET 1
        sleep 0.5
        gpio_set_value $WB_GPIO_GSM_RESET 0
        sleep 0.5
    fi

    if [[ ${WB_GSM_POWER_TYPE} = "2" ]]; then
        debug "Resetting GSM modem using POWER FET"
        gpio_set_value $WB_GPIO_GSM_POWER 0
        sleep 0.5
        gpio_set_value $WB_GPIO_GSM_POWER 1
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
    debug "Try to switch off GSM modem "

    if [[ ${WB_GSM_POWER_TYPE} = "1" ]]; then
        debug "resetting GSM modem first"
        reset
        sleep 3
    fi

    debug "Send power down command "
    set_speed
    echo  -e "AT+CPOWD=1\r\n" > $PORT # for SIMCOM
    echo  -e "AT+CPWROFF\r\n" > $PORT # for SIMCOM

    if [[ -n ${WB_GPIO_GSM_STATUS} ]]; then
        debug "Waiting for modem to stop"
        max_tries=25

        for ((i=0; i<=upperlim; i++)); do
            if [[ "`gpio_get_value ${WB_GPIO_GSM_STATUS}`" = "0" ]]; then
                break
            fi
            sleep 0.2
        done
    else
        sleep 5
    fi

    unlink_ports

    if [[ ${WB_GSM_POWER_TYPE} = "2" ]]; then
        debug "physically switching off GSM modem using POWER FET"
        gpio_set_value $WB_GPIO_GSM_POWER 0
    fi;




}

function ensure_on() {
    if [[ -n "${WB_GPIO_GSM_STATUS}" ]]; then
        if [[ "`gpio_get_value ${WB_GPIO_GSM_STATUS}`" = "1" ]]; then
            debug "Modem is already switched on"
            return
        fi
    else
        switch_off
    fi

    if [[ ${WB_GSM_POWER_TYPE} = "2" ]]; then
        debug "switching on GSM modem using POWER FET"
        gpio_set_value $WB_GPIO_GSM_POWER 1
    fi;

    toggle

    if [[ -n "${WB_GPIO_GSM_STATUS}" ]]; then
        debug "Waiting for modem to start"
        max_tries=30

        for ((i=0; i<=max_tries; i++)); do
            if [[ "`gpio_get_value ${WB_GPIO_GSM_STATUS}`" = "1" ]]; then
                break
            fi
            sleep 0.1
        done
    else
        sleep 2
    fi

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
    #~ set_speed
    local RC=0
    if [[ -n "${WB_GPIO_GSM_STATUS}" ]]; then
        if [[ "`gpio_get_value ${WB_GPIO_GSM_STATUS}`" = "0" ]]; then
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
