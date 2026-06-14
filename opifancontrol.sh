#!/bin/bash
OPIFANCONTROL_VERSION="3.0.0"

PWM_CHIP="/sys/class/pwm/pwmchip3"
PWM_CHANNEL=0

TARGET_TEMP=55
SAFE_TEMP_HYSTERESIS=1

MIN_PWM=0
MAX_PWM=1000
PWM_STEP=25

TEMP_POLL_SECONDS=2

PWM_PERIOD_NS=40000   # 25 kHz = 40,000 ns period

cleanup() {
    if [ -e "$PWM_CHIP/pwm$PWM_CHANNEL/enable" ]; then
        echo 0 > "$PWM_CHIP/pwm$PWM_CHANNEL/enable" 2>/dev/null
    fi
    if [ -e "$PWM_CHIP/pwm$PWM_CHANNEL" ]; then
        echo 0 > "$PWM_CHIP/pwm$PWM_CHANNEL/duty_cycle" 2>/dev/null
    fi
    if [ -e "$PWM_CHIP/pwm$PWM_CHANNEL" ]; then
        echo "$PWM_CHANNEL" > "$PWM_CHIP/unexport" 2>/dev/null
    fi
    exit 0
}

trap cleanup INT TERM EXIT

init_pwm() {
    if [ ! -d "$PWM_CHIP" ]; then
        echo "PWM chip not found: $PWM_CHIP"
        exit 1
    fi

    if [ ! -d "$PWM_CHIP/pwm$PWM_CHANNEL" ]; then
        echo "$PWM_CHANNEL" > "$PWM_CHIP/export"
        sleep 0.1
    fi

    echo 0 > "$PWM_CHIP/pwm$PWM_CHANNEL/enable"
    echo "$PWM_PERIOD_NS" > "$PWM_CHIP/pwm$PWM_CHANNEL/period"
    echo 0 > "$PWM_CHIP/pwm$PWM_CHANNEL/duty_cycle"
}

set_pwm_scaled() {
    local pwm_value="$1"

    if [ "$pwm_value" -lt 0 ]; then
        pwm_value=0
    fi
    if [ "$pwm_value" -gt "$MAX_PWM" ]; then
        pwm_value="$MAX_PWM"
    fi

    local duty_ns=$(( pwm_value * PWM_PERIOD_NS / MAX_PWM ))

    echo 0 > "$PWM_CHIP/pwm$PWM_CHANNEL/enable"
    echo "$PWM_PERIOD_NS" > "$PWM_CHIP/pwm$PWM_CHANNEL/period"
    echo "$duty_ns" > "$PWM_CHIP/pwm$PWM_CHANNEL/duty_cycle"
    echo 1 > "$PWM_CHIP/pwm$PWM_CHANNEL/enable"
}

echo "Starting OPi Fan Controller v$OPIFANCONTROL_VERSION"

init_pwm
set_pwm_scaled 0

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
        set_pwm_scaled 0

        sleep "$TEMP_POLL_SECONDS"
        continue
    fi

    # ---- HEAT ACTIVE ----
    if [ "$FAN_LOCKED" -eq 0 ]; then
        # first activation jump
        CURRENT_PWM=$MIN_PWM
        set_pwm_scaled "$CURRENT_PWM"
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

            set_pwm_scaled "$CURRENT_PWM"
            echo "Heating → PWM=$CURRENT_PWM Temp=${CPU_TEMP}C"
        else
            # temp dropped → HOLD speed (no ramp down)
            echo "Stable → hold PWM=$CURRENT_PWM Temp=${CPU_TEMP}C"
        fi
    fi

    sleep "$TEMP_POLL_SECONDS"
done
