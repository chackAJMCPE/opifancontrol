#!/bin/bash
OPIFANCONTROL_VERSION="3.0.0"

FAN_GPIO_PIN=2

TARGET_TEMP=55
SAFE_TEMP_HYSTERESIS=1

MIN_PWM=350
MAX_PWM=1000
PWM_STEP=25

TEMP_POLL_SECONDS=2

if ! command -v gpio >/dev/null 2>&1; then
    echo "gpio not found"
    exit 1
fi

cleanup() {
    gpio pwm "$FAN_GPIO_PIN" 0 >/dev/null 2>&1
    exit 0
}

trap cleanup INT TERM EXIT

init_pwm() {
    gpio mode "$FAN_GPIO_PIN" pwm >/dev/null 2>&1
}

echo "Starting OPi Fan Controller v$OPIFANCONTROL_VERSION"

init_pwm
gpio pwm "$FAN_GPIO_PIN" 0

CURRENT_PWM=0
FAN_LOCKED=0

while true; do

    CPU_TEMP=$(cat /sys/class/thermal/thermal_zone1/temp 2>/dev/null \
            || cat /sys/class/thermal/thermal_zone0/temp)

    CPU_TEMP=$((CPU_TEMP / 1000))

    # ---- OFF STATE ----
    if [ "$CPU_TEMP" -le "$TARGET_TEMP" ]; then
        if [ "$CURRENT_PWM" -ne 0 ]; then
            echo "Cooling down → OFF (temp=${CPU_TEMP}C)"
        fi
        CURRENT_PWM=0
        FAN_LOCKED=0
        gpio pwm "$FAN_GPIO_PIN" 0

        sleep "$TEMP_POLL_SECONDS"
        continue
    fi

    # ---- HEAT ACTIVE ----
    if [ "$FAN_LOCKED" -eq 0 ]; then
        # first activation jump
        CURRENT_PWM=$MIN_PWM
        gpio pwm "$FAN_GPIO_PIN" "$CURRENT_PWM"
        FAN_LOCKED=1
        echo "Fan started at PWM=$CURRENT_PWM (temp=${CPU_TEMP}C)"
    else
        # reactive control loop

        if [ "$CPU_TEMP" -gt "$TARGET_TEMP" ]; then
            # still hot → increase slowly
            CURRENT_PWM=$((CURRENT_PWM + PWM_STEP))

            if [ "$CURRENT_PWM" -gt "$MAX_PWM" ]; then
                CURRENT_PWM=$MAX_PWM
            fi

            gpio pwm "$FAN_GPIO_PIN" "$CURRENT_PWM"
            echo "Heating → PWM=$CURRENT_PWM Temp=${CPU_TEMP}C"
        else
            # temp dropped → HOLD speed (no ramp down)
            echo "Stable → hold PWM=$CURRENT_PWM Temp=${CPU_TEMP}C"
        fi
    fi

    sleep "$TEMP_POLL_SECONDS"
done
