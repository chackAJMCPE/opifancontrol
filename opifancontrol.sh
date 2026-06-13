#!/bin/bash
OPIFANCONTROL_VERSION="1.1.0"

# Default values
TARGET_TEMP=55          # setpoint
TEMP_FULL=70            # full fan speed at/above this temp
FAN_START_PERCENT=30    # minimum non-zero PWM once temp rises above TARGET_TEMP
TEMP_POLL_SECONDS=2

RAMP_UP_DELAY_SECONDS=15
RAMP_DOWN_DELAY_SECONDS=60
RAMP_PERCENT_PER_STEP=2
RAMP_STEP_DELAY=0.03

# Orange Pi 5 / WiringOP recipe
FAN_GPIO_PIN=2
PWM_RANGE=480
PWM_CLOCK=2

CONFIG_FILE="${1:-/etc/opifancontrol.conf}"

if ! command -v gpio > /dev/null; then
    echo "Error: gpio command not found. Please install WiringOP."
    exit 1
fi

if [ -r "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
else
    echo "Warning: Configuration file not found at /etc/opifancontrol.conf. Using default values."
fi

CURRENT_PWM=0
LAST_RAMPED_DOWN_TS=0

debug () {
    if [ "$DEBUG" = true ]; then
        echo "$1"
    fi
}

percent_to_pwm() {
    local percent=$1
    if [ "$percent" -gt 100 ]; then percent=100; fi
    if [ "$percent" -lt 0 ]; then percent=0; fi
    echo $(((percent * PWM_RANGE + 50) / 100))
}

temp_to_pwm() {
    local temp=$1

    if [ "$temp" -le "$TARGET_TEMP" ]; then
        echo 0
        return
    fi

    if [ "$temp" -ge "$TEMP_FULL" ]; then
        echo "$PWM_RANGE"
        return
    fi

    local start_pwm
    start_pwm=$(percent_to_pwm "$FAN_START_PERCENT")

    local span=$((TEMP_FULL - TARGET_TEMP))
    local delta=$((temp - TARGET_TEMP))

    # Linear ramp: at TARGET_TEMP+1 => at least start_pwm, at TEMP_FULL => PWM_RANGE
    local pwm=$(( start_pwm + (delta * (PWM_RANGE - start_pwm) + span / 2) / span ))

    if [ "$pwm" -gt "$PWM_RANGE" ]; then
        pwm="$PWM_RANGE"
    fi

    echo "$pwm"
}

cleanup() {
    echo "Exiting opifancontrol and setting fan pin to 0 PWM"
    gpio pwm "$FAN_GPIO_PIN" 0
    exit 0
}

smooth_ramp() {
    local current_pwm=$1
    local target_pwm=$2

    local ramp_step=$(((PWM_RANGE * RAMP_PERCENT_PER_STEP + 50) / 100))
    if [ "$ramp_step" -lt 1 ]; then ramp_step=1; fi

    while [ "$current_pwm" -ne "$target_pwm" ]; do
        if [ "$target_pwm" -eq 0 ]; then
            current_pwm=$((current_pwm - ramp_step))
            if [ "$current_pwm" -le 0 ]; then
                current_pwm=0
            fi
        elif [ "$current_pwm" -eq 0 ] && [ "$target_pwm" -gt 0 ]; then
            current_pwm=$(percent_to_pwm "$FAN_START_PERCENT")
            if [ "$current_pwm" -gt "$target_pwm" ]; then
                current_pwm=$target_pwm
            fi
        elif [ "$current_pwm" -lt "$target_pwm" ]; then
            current_pwm=$((current_pwm + ramp_step))
            if [ "$current_pwm" -gt "$target_pwm" ]; then
                current_pwm=$target_pwm
            fi
        else
            current_pwm=$((current_pwm - ramp_step))
            if [ "$current_pwm" -lt "$target_pwm" ]; then
                current_pwm=$target_pwm
            fi
        fi

        gpio pwm "$FAN_GPIO_PIN" "$current_pwm"
        sleep "$RAMP_STEP_DELAY"
    done

    CURRENT_PWM=$target_pwm
}

# Initialize PWM
gpio mode "$FAN_GPIO_PIN" pwm
gpio pwmc "$PWM_CLOCK"
gpio pwmr "$PWM_RANGE"
gpio pwm "$FAN_GPIO_PIN" 0

trap cleanup EXIT

echo "Starting opifancontrol (v$OPIFANCONTROL_VERSION) ..."
echo "Target temp: $TARGET_TEMP C"
echo "Full speed temp: $TEMP_FULL C"
echo "Minimum fan start percent: $FAN_START_PERCENT%"
echo "PWM range: $PWM_RANGE"
echo "PWM clock: $PWM_CLOCK"
echo "Fan GPIO pin: $FAN_GPIO_PIN"
echo "Temperature poll interval: $TEMP_POLL_SECONDS seconds"
echo "Ramp up delay: $RAMP_UP_DELAY_SECONDS seconds"
echo "Ramp down delay: $RAMP_DOWN_DELAY_SECONDS seconds"

if [ "$DEBUG" = true ]; then
    echo "Debugging enabled"
else
    echo "Debugging is disabled. To log fan speed changes, set DEBUG=true in /etc/opifancontrol.conf"
fi

while true; do
    CPU_TEMP=$(cat /sys/class/thermal/thermal_zone1/temp)
    CPU_TEMP=$((CPU_TEMP / 1000))

    TARGET_PWM=$(temp_to_pwm "$CPU_TEMP")

    if [ "$TARGET_PWM" -ne "$CURRENT_PWM" ]; then
        BASE_RAMP_UP_DELAY_TS=$(date +%s)

        if [ "$TARGET_PWM" -gt "$CURRENT_PWM" ] && [ $((LAST_RAMPED_DOWN_TS + RAMP_UP_DELAY_SECONDS)) -gt "$BASE_RAMP_UP_DELAY_TS" ]; then
            RAMP_UP_DELAY_REMAIN_SECONDS=$(($RAMP_UP_DELAY_SECONDS - $BASE_RAMP_UP_DELAY_TS + $LAST_RAMPED_DOWN_TS))
            debug "Delay of $RAMP_UP_DELAY_REMAIN_SECONDS sec before turning on the fan ... Target PWM: $TARGET_PWM"
            sleep "$RAMP_UP_DELAY_REMAIN_SECONDS"
        fi

        if [ "$TARGET_PWM" -eq 0 ] && [ "$CURRENT_PWM" -ne 0 ]; then
            debug "Delay of $RAMP_DOWN_DELAY_SECONDS sec before turning off the fan ... Target PWM: $TARGET_PWM"
            sleep "$RAMP_DOWN_DELAY_SECONDS"
            debug "Turning off the fan"
            LAST_RAMPED_DOWN_TS=$(date +%s)
        fi

        debug "Changing Fan Speed | CPU temp: $CPU_TEMP, target PWM: $TARGET_PWM, current PWM: $CURRENT_PWM"
        smooth_ramp "$CURRENT_PWM" "$TARGET_PWM"
    fi

    sleep "$TEMP_POLL_SECONDS"
done
