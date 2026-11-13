#!/system/bin/sh

MODDIR=${0%/*}
. "${MODDIR}/compat.sh"
. "${MODDIR}/wifi-policy.sh"
opb_is_target_device || { log -t OnePlusBeastHB "$OPB_DEVICE_REASON"; exit 0; }
PID_FILE="$MODDIR/wifi-heartbeat.pid"
STATUS_FILE="$MODDIR/wifi-heartbeat.status"
LOG_FILE="$MODDIR/wifi-heartbeat.log"

if [ -r "$PID_FILE" ]; then
    OLD_PID="$(cat "$PID_FILE" 2>/dev/null)"
    case "$OLD_PID" in
        ''|*[!0-9]*) ;;
        *)
            if kill -0 "$OLD_PID" 2>/dev/null &&
                tr '\000' '\n' < "/proc/$OLD_PID/cmdline" 2>/dev/null | grep -Fxq "$MODDIR/wifi-heartbeat.sh"; then
                exit 0
            fi
            ;;
    esac
fi
echo "$$" > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT
trap 'exit 0' INT TERM

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
    log -t OnePlusBeastHB "$1"
    if [ "$(wc -c < "$LOG_FILE")" -gt 131072 ]; then
        tail -n 300 "$LOG_FILE" > "$LOG_FILE.tmp"
        mv -f "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

until [ "$(opb_getprop sys.boot_completed)" = 1 ]; do sleep 2; done
INTERVAL="$(opb_getprop persist.sys.opb.6ghz.heartbeat_interval)"
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=5 ;; esac
[ "$INTERVAL" -ge 5 ] || INTERVAL=5
[ "$INTERVAL" -le 60 ] || INTERVAL=60
opb_probe_wifi_commands
OPB_BAD_SAMPLES=0
LAST_STATE=""
PULSE_COUNT=0
log_message "passive monitor started interval=${INTERVAL}s automatic_reconnect=disabled"

while [ "$(opb_getprop persist.sys.opb.6ghz.heartbeat)" != 0 ]; do
    # No country reassertion, active scans, resource reloads, Wi-Fi toggles,
    # reassociation, HAL restarts or driver reloads in this observer.
    opb_monitor_step
    if [ "$OPB_POLICY_STATE" != "$LAST_STATE" ]; then
        log_message "state=$OPB_POLICY_STATE action=$OPB_POLICY_ACTION six_ghz=$OPB_CHANNEL_STATE"
        LAST_STATE="$OPB_POLICY_STATE"
    fi
    REG_CC="$(opb_get_reg_country)"
    echo "timestamp=$(date +%s) state=$OPB_POLICY_STATE action=$OPB_POLICY_ACTION link=$OPB_LINK_STATE frequency_mhz=$OPB_LINK_FREQ six_ghz=$OPB_CHANNEL_STATE scan_6ghz=$OPB_SCAN_STATE bad_samples=$OPB_BAD_SAMPLES reg_country=$REG_CC automatic_reconnect=disabled" > "$STATUS_FILE.tmp"
    mv -f "$STATUS_FILE.tmp" "$STATUS_FILE"
    PULSE_COUNT=$((PULSE_COUNT + 1))
    if [ $((PULSE_COUNT % 12)) -eq 0 ]; then opb_probe_wifi_commands; fi
    sleep "$INTERVAL"
done
log_message 'passive monitor stopped'
