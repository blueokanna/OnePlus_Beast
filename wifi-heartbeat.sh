#!/system/bin/sh

MODDIR=${0%/*}
PID_FILE="${MODDIR}/wifi-heartbeat.pid"
STATUS_FILE="${MODDIR}/wifi-heartbeat.status"
LOG_FILE="${MODDIR}/wifi-heartbeat.log"
LOG_TAG="OnePlusBeastHB"
TARGET_CC="US"

if [ -r "$PID_FILE" ]; then
    OLD_PID="$(cat "$PID_FILE" 2>/dev/null)"
    case "$OLD_PID" in
        ''|*[!0-9]*) ;;
        *)
            kill -0 "$OLD_PID" >/dev/null 2>&1 && exit 0
            ;;
    esac
fi

echo "$$" > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT INT TERM

log_message() {
    local message="$1"
    local stamp=""

    stamp="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    echo "${stamp} ${message}" >> "$LOG_FILE"
    log -t "$LOG_TAG" "$message"

    if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE")" -gt 131072 ]; then
        tail -n 300 "$LOG_FILE" > "${LOG_FILE}.tmp"
        mv -f "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
}

find_resetprop() {
    local candidate=""

    candidate="$(command -v resetprop 2>/dev/null)"
    [ -n "$candidate" ] && {
        echo "$candidate"
        return
    }

    for candidate in \
        /data/adb/magisk/resetprop \
        /data/adb/ksu/bin/resetprop \
        /data/adb/ap/bin/resetprop; do
        [ -x "$candidate" ] && {
            echo "$candidate"
            return
        }
    done

    echo ""
}

RESETPROP="$(find_resetprop)"

set_runtime_prop() {
    local name="$1"
    local value="$2"

    [ "$(getprop "$name")" = "$value" ] && return
    if [ -n "$RESETPROP" ]; then
        "$RESETPROP" "$name" "$value" >/dev/null 2>&1
    else
        setprop "$name" "$value" >/dev/null 2>&1
    fi
}

get_interval() {
    local value=""

    value="$(getprop persist.sys.opb.6ghz.heartbeat_interval)"
    case "$value" in
        ''|*[!0-9]*) value=2 ;;
    esac
    [ "$value" -lt 1 ] && value=1
    [ "$value" -gt 10 ] && value=10
    echo "$value"
}

get_cooldown() {
    local value=""

    value="$(getprop persist.sys.opb.6ghz.recovery_cooldown)"
    case "$value" in
        ''|*[!0-9]*) value=60 ;;
    esac
    [ "$value" -lt 30 ] && value=30
    [ "$value" -gt 600 ] && value=600
    echo "$value"
}

is_wifi_enabled() {
    local value=""

    value="$(settings get global wifi_on 2>/dev/null)"
    case "$value" in
        1|2) echo 1 ;;
        *) echo 0 ;;
    esac
}

get_radio_signature() {
    echo "$(settings get global airplane_mode_on 2>/dev/null)|$(getprop gsm.sim.state)|$(getprop gsm.operator.numeric)|$(getprop gsm.operator.iso-country)"
}

get_6ghz_channel_state() {
    local state=""

    command -v iw >/dev/null 2>&1 || {
        echo "unknown"
        return
    }

    state="$(iw phy 2>/dev/null | awk '
        /^Wiphy / { phy_seen = 1 }
        /MHz/ {
            phy_seen = 1
            for (i = 1; i <= NF; i++) {
                if ($i == "MHz") {
                    freq = $(i - 1) + 0
                    if (freq >= 5925 && freq <= 7125) {
                        seen = 1
                        if ($0 !~ /disabled/) enabled = 1
                    }
                }
            }
        }
        END {
            if (!phy_seen) print "unknown"
            else if (enabled) print "enabled"
            else if (seen) print "disabled"
            else print "absent"
        }
    ')"

    [ -n "$state" ] && echo "$state" || echo "unknown"
}

country_heartbeat() {
    set_runtime_prop wifi.country_code "$TARGET_CC"
    set_runtime_prop vendor.wifi.country_code "$TARGET_CC"
    set_runtime_prop persist.sys.wifi.country_code "$TARGET_CC"
    set_runtime_prop persist.vendor.wifi.country_code "$TARGET_CC"
    set_runtime_prop persist.sys.wifi.default_country_code "$TARGET_CC"
    set_runtime_prop persist.vendor.wifi.default_country_code "$TARGET_CC"
    set_runtime_prop wlan.driver.country "$TARGET_CC"
    set_runtime_prop vendor.wlan.country_code "$TARGET_CC"
    set_runtime_prop vendor.wifi.ap_country_code "$TARGET_CC"
    set_runtime_prop persist.vendor.wifi.dynamic_regdom 0
    set_runtime_prop persist.sys.wifi.dynamic_regdom 0
    set_runtime_prop persist.vendor.wifi.world_mode 0
    set_runtime_prop persist.vendor.wlan.global_regdom_mode 0
    set_runtime_prop persist.vendor.wifi.allow_11d 0
    set_runtime_prop persist.vendor.extreme.wifi.6ghz.enabled 1
    set_runtime_prop persist.vendor.wifi.wifi7_enabled 1
    set_runtime_prop persist.vendor.wifi.eht_enabled 1
    set_runtime_prop persist.sys.oplus.wifi6ghz.support 1
    set_runtime_prop persist.vendor.oplus.wifi6ghz.support 1

    if [ -n "$RESETPROP" ]; then
        "$RESETPROP" -n ro.boot.wificountrycode "$TARGET_CC" >/dev/null 2>&1
    fi
    command -v iw >/dev/null 2>&1 && iw reg set "$TARGET_CC" >/dev/null 2>&1
    command -v cmd >/dev/null 2>&1 && \
        cmd wifi force-country-code enabled "$TARGET_CC" >/dev/null 2>&1
}

refresh_framework_state() {
    settings put global wifi_country_code "$TARGET_CC" >/dev/null 2>&1
    settings put global wifi_6ghz_support 1 >/dev/null 2>&1
    cmd wifi reload-resources >/dev/null 2>&1
    cmd wifi start-scan >/dev/null 2>&1
}

list_running_wifi_services() {
    getprop 2>/dev/null | sed -n 's/^\[init\.svc\.\([^]]*\)\]: \[running\]$/\1/p' | \
        while IFS= read -r service_name; do
            case "$service_name" in
                wificond|*wifi*hal*|*wifi_hal*)
                    echo "$service_name"
                    ;;
            esac
        done
}

restart_wifi_services() {
    local services="$1"
    local service_name=""

    for service_name in $services; do
        setprop ctl.restart "$service_name" >/dev/null 2>&1
    done
    sleep 1
}

hard_recover_wifi() {
    local reason="$1"
    local wifi_was_on=""
    local running_services=""

    wifi_was_on="$(is_wifi_enabled)"
    running_services="$(list_running_wifi_services)"
    log_message "hard recovery reason=${reason} wifi_on=${wifi_was_on}"

    cmd wifi force-country-code disabled >/dev/null 2>&1
    country_heartbeat
    refresh_framework_state

    [ "$wifi_was_on" = "1" ] || return

    svc wifi disable >/dev/null 2>&1
    sleep 2
    restart_wifi_services "$running_services"
    country_heartbeat
    svc wifi enable >/dev/null 2>&1
    sleep 4
    country_heartbeat
    refresh_framework_state
    log_message "hard recovery completed six_ghz=$(get_6ghz_channel_state)"
}

probe_runtime_support() {
    local force_rc=127
    local iw_rc=127

    if command -v cmd >/dev/null 2>&1; then
        cmd wifi force-country-code enabled "$TARGET_CC" >/dev/null 2>&1
        force_rc=$?
    fi
    if command -v iw >/dev/null 2>&1; then
        iw reg set "$TARGET_CC" >/dev/null 2>&1
        iw_rc=$?
    fi
    log_message "runtime probe force_country_rc=${force_rc} iw_reg_rc=${iw_rc}"
}

until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 2
done

INTERVAL="$(get_interval)"
COOLDOWN="$(get_cooldown)"
LAST_SIGNATURE="$(get_radio_signature)"
PENDING_EVENT=3
BAD_STREAK=0
PULSE_COUNT=0
LAST_RECOVERY=0
LAST_STATE="unknown"

if [ -n "$RESETPROP" ]; then
    RESETPROP_STATE="yes"
else
    RESETPROP_STATE="no"
fi
log_message "heartbeat started interval=${INTERVAL}s cooldown=${COOLDOWN}s resetprop=${RESETPROP_STATE}"
probe_runtime_support

while [ "$(getprop persist.sys.opb.6ghz.heartbeat)" != "0" ]; do
    NOW="$(date +%s 2>/dev/null)"
    case "$NOW" in
        ''|*[!0-9]*) NOW=0 ;;
    esac

    SIGNATURE="$(get_radio_signature)"
    if [ "$SIGNATURE" != "$LAST_SIGNATURE" ]; then
        LAST_SIGNATURE="$SIGNATURE"
        PENDING_EVENT=3
        log_message "radio state changed; debounce recovery armed signature=${SIGNATURE}"
    elif [ "$PENDING_EVENT" -gt 0 ]; then
        PENDING_EVENT=$((PENDING_EVENT - 1))
    fi

    country_heartbeat
    PULSE_COUNT=$((PULSE_COUNT + 1))
    if [ $((PULSE_COUNT % 15)) -eq 0 ]; then
        refresh_framework_state
    fi

    CHANNEL_STATE="$(get_6ghz_channel_state)"
    if [ "$CHANNEL_STATE" != "$LAST_STATE" ]; then
        log_message "6 GHz channel state=${CHANNEL_STATE}"
        LAST_STATE="$CHANNEL_STATE"
    fi

    case "$CHANNEL_STATE" in
        disabled|absent) BAD_STREAK=$((BAD_STREAK + 1)) ;;
        *) BAD_STREAK=0 ;;
    esac

    if [ "$PENDING_EVENT" -eq 0 ]; then
        hard_recover_wifi "radio-transition"
        LAST_RECOVERY="$NOW"
        PENDING_EVENT=-1
        BAD_STREAK=0
    elif [ "$BAD_STREAK" -ge 3 ] && [ $((NOW - LAST_RECOVERY)) -ge "$COOLDOWN" ]; then
        hard_recover_wifi "channel-${CHANNEL_STATE}"
        LAST_RECOVERY="$NOW"
        BAD_STREAK=0
    fi

    if [ $((PULSE_COUNT % 15)) -eq 0 ]; then
        REG_CC="$(iw reg get 2>/dev/null | awk '/country/{print $2; exit}' | tr -d ':')"
        PROP_CC="$(getprop persist.vendor.wifi.country_code)"
        echo "timestamp=${NOW} country=${TARGET_CC} prop_country=${PROP_CC} reg_country=${REG_CC} six_ghz=${CHANNEL_STATE} signature=${SIGNATURE}" > "$STATUS_FILE"
    fi

    sleep "$INTERVAL"
done

log_message "heartbeat stopped by persist.sys.opb.6ghz.heartbeat=0"
