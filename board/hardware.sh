#!/bin/bash

# GPIO functions
SYSFS_GPIO="/sys/class/gpio"
gpio_attr_path() {
	echo "${SYSFS_GPIO}/${1}${2:+/${2}}"
}

gpio_export() {
	[[ -e "$(gpio_attr_path "$1")" ]] || echo "$1" > "$SYSFS_GPIO/export"
}

gpio_set_dir() {
	local p
    p=$(gpio_attr_path "$1" direction || die)
	[[ "$(cat "$p")" == "$2" ]] || echo "$2" > "$p"
}

gpio_set_value() {
	echo "$2" > "$(gpio_attr_path "$1" value)"
}

gpio_set_inverted() {
	echo "$2" > "$(gpio_attr_path "$1" active_low)"
}

gpio_get_value() {
	cat "$(gpio_attr_path "$1" value)"
}

# LED functions
led() {
	echo "$3" > "/sys/class/leds/$1/$2" 2>/dev/null || true
}

led_on() {
	led "$1" trigger none
	led "$1" brightness 255
}

led_off() {
	led "$1" trigger none
	led "$1" brightness 0
}

led_blink() {
	local delay="${2:-500}"
	led "$1" trigger timer
	led "$1" delay_on "$delay"
	led "$1" delay_off "${3:-$delay}"
}

# PWM functions
SYSFS_PWM="/sys/class/pwm"
pwm_path() {
	echo "$SYSFS_PWM/pwmchip${1}/pwm${2}"
}

pwm_export() {
	[[ -e "$(pwm_path "$1" "$2")" ]] || echo "$2" > "$SYSFS_PWM/pwmchip${1}/export"
}

pwm_set_params() {
	local p
    p=$(pwm_path "$1" "$2" || die)
    local period=$((1000000000/${3}))
    local duty=$((${4}*period/1000))

	echo "$period" > "$p/period"
	echo "$duty" > "$p/duty_cycle"
}

pwm_enable() {
	echo 1 > "$(pwm_path "$1" "$2")/enable"
}

pwm_disable() {
	echo 1 > "$(pwm_path "$1" "$2")/disable"
}
