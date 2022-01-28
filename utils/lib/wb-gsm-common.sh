#!/bin/bash

. /usr/lib/wb-utils/wb_env.sh
wb_source "hardware"
wb_source "of"


DEFAULT_BAUDRATE=115200


function has_uart() {
    # usually modem has UART for AT-commands and USB-uart for data connection
    # sometimes uart may be not present (ex: no uart in wb7 board); we defining "usb-soc-addr" prop in these cases
    ! of_has_prop "wirenboard/gsm" "usb-soc-addr"
}


if has_uart; then
    PORT=/dev/ttyGSM
    POWERON_DELAY=0
    debug "Connecting via uart; port: $PORT"
else
    PORT=/dev/ttyUSB1
    POWERON_DELAY=10
    debug "Connecting via usb; port: $PORT"
    # TODO: port by modem model?
fi


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
    local nodename="wirenboard/gsm"

    if of_has_prop $nodename "model"; then
        ret=$(of_get_prop_str $nodename "model")
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

    if has_uart; then
        # UART has present always (even if modem is turned off)
        if [[ ! -c "$PORT" || ! -r "$PORT" || ! -w "$PORT" ]]; then
            debug "Cannot access GSM modem serial port, exiting"
            exit 1
        else
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

    if has_uart; then
        stty -F $PORT ${BAUDRATE} cs8 -cstopb -parenb -icrnl
    fi
}

function _try_set_baud() {
    local RC=1
    if [[ $(test_connection) == 0 ]] ; then
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
    sleep $POWERON_DELAY

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

    set_speed

    # Set default baudrate, then try to make modem to detect
    # baudrate by sending AAA bytes.

    # This is needed for SIM5300E and other models that
    # reset to autobauding on each power on

    synchronize_baudrate
}

function test_connection() {
    /usr/sbin/chat -v   TIMEOUT 5 ABORT "ERROR" ABORT "BUSY" "" AT OK "" > $PORT < $PORT
    RC=$?
    echo $RC
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
        RC=$(test_connection)
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
            RC=$(test_connection)
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
