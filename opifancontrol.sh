#!/bin/bash
OPIFANCONTROL_VERSION="2.0.0"

#
# Orange Pi 5 Fan Controller
#
# Uses ONLY the default PWM configuration provided by:
#   gpio mode 2 pwm
#
# Assumptions:
#   gpio pwm 2 0      = fan off
#   gpio pwm 2 1000   = full speed
#   fan does NOT like PWM values between 1-249
#

# Fan configuration
FAN_GPIO_PIN=2
PWM_RANGE=1000
MIN_RUNNING_PWM=250

# Temperature control
TARGET_TEMP=55      # Fan starts above this temperature
FULL_TEMP=75        # Full speed at or above this temperature
TEMP_POLL_SECONDS=2

# Ramp behavior
RAMP_UP_DELAY_SECONDS=5
RAMP_DOWN_DELAY_SECONDS=30
RAMP_PERCENT_PER_STEP=2
RAMP_STEP_DELAY=0.03

CONFIG_FILE="${1:-/etc/opifancontrol.conf}"

if ! command -v gpio >/dev/null 2>&1; then
    echo "Error: gpio command not found."
    exit 1
fi

if [ -r "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

CURRENT_PWM=0
LAST_RAMPED_DOWN_TS=0

debug() {
    if [ "$DEBUG" = true ]; then
        echo "$(date '+%H:%M:%S') $1"
    fi
}

init_pwm() {
    gpio mode "$FAN_GPIO_PIN" pwm >/dev/null 2>&1
}

cleanup() {
    echo
    echo "Stopping fan controller..."
    gpio pwm "$FAN_GPIO_PIN" 0 >/dev/null 2>&1
    exit 0
}

trap cleanup INT TERM EXIT

temp_to_pwm() {
    local temp=$1

    if [ "$temp" -le "$TARGET_TEMP" ]; then
        echo 0
        return
    fi

    if [ "$temp" -ge "$FULL_TEMP" ]; then
        echo "$PWM_RANGE"
        return
    fi

    local span=$((FULL_TEMP - TARGET_TEMP))
    local delta=$((temp - TARGET_TEMP))

    echo $((MIN_RUNNING_PWM + (delta * (PWM_RANGE - MIN_RUNNING_PWM)) / span))
}

smooth_ramp() {
    local current_pwm=$1
    local target_pwm=$2

    # Reinitialize PWM before every ramp
    init_pwm

    local ramp_step=$(((PWM_RANGE * RAMP_PERCENT_PER_STEP + 50) / 100))
    [ "$ramp_step" -lt 1 ] && ramp_step=1

    while [ "$current_pwm" -ne "$target_pwm" ]; do

        if [ "$target_pwm" -eq 0 ]; then
            current_pwm=$((current_pwm - ramp_step))
            if [ "$current_pwm" -le 0 ]; then
                current_pwm=0
            fi

        elif [ "$current_pwm" -eq 0 ] && [ "$target_pwm" -gt 0 ]; then
            # Fan dislikes low PWM values.
            current_pwm=$MIN_RUNNING_PWM
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

echo "Starting Orange Pi Fan Controller v$OPIFANCONTROL_VERSION"
echo "Fan pin: $FAN_GPIO_PIN"
echo "PWM range: 0-$PWM_RANGE"
echo "Minimum running PWM: $MIN_RUNNING_PWM"
echo "Target temperature: ${TARGET_TEMP}C"
echo "Full speed temperature: ${FULL_TEMP}C"
echo

# Initial PWM setup
init_pwm
gpio pwm "$FAN_GPIO_PIN" 0

while true; do

    if [ -f /sys/class/thermal/thermal_zone1/temp ]; then
        CPU_TEMP=$(cat /sys/class/thermal/thermal_zone1/temp)
    else
        CPU_TEMP=$(cat /sys/class/thermal/thermal_zone0/temp)
    fi

    CPU_TEMP=$((CPU_TEMP / 1000))

    TARGET_PWM=$(temp_to_pwm "$CPU_TEMP")

    # Never use the fan's unhappy zone (1-249)
    if [ "$TARGET_PWM" -gt 0 ] && [ "$TARGET_PWM" -lt "$MIN_RUNNING_PWM" ]; then
        TARGET_PWM=$MIN_RUNNING_PWM
    fi

    if [ "$TARGET_PWM" -ne "$CURRENT_PWM" ]; then

        NOW=$(date +%s)

        if [ "$TARGET_PWM" -gt "$CURRENT_PWM" ] \
           && [ $((LAST_RAMPED_DOWN_TS + RAMP_UP_DELAY_SECONDS)) -gt "$NOW" ]; then

            REMAIN=$((LAST_RAMPED_DOWN_TS + RAMP_UP_DELAY_SECONDS - NOW))

            if [ "$REMAIN" -gt 0 ]; then
                debug "Waiting ${REMAIN}s before turning fan on"
                sleep "$REMAIN"
            fi
        fi

        if [ "$TARGET_PWM" -eq 0 ] && [ "$CURRENT_PWM" -ne 0 ]; then
            debug "Waiting ${RAMP_DOWN_DELAY_SECONDS}s before turning fan off"
            sleep "$RAMP_DOWN_DELAY_SECONDS"
            LAST_RAMPED_DOWN_TS=$(date +%s)
        fi

        debug "Temp=${CPU_TEMP}C PWM ${CURRENT_PWM} -> ${TARGET_PWM}"

        smooth_ramp "$CURRENT_PWM" "$TARGET_PWM"
    fi

    sleep "$TEMP_POLL_SECONDS"
done
