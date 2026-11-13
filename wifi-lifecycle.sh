#!/system/bin/sh
# Bounded initialization after lifecycle events; independent of the passive monitor.
opb_uptime() { cut -d. -f1 /proc/uptime; }
opb_boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null; }
opb_process_start() {
    sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'
}
opb_framework_epoch() {
    local pid start boot
    [ "$(opb_getprop sys.boot_completed)" = 1 ] || return 1
    pid="$(pidof system_server 2>/dev/null)"
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    start="$(opb_process_start "$pid")"; boot="$(opb_boot_id)"
    [ -n "$start" ] && [ -n "$boot" ] || return 1
    echo "$boot:$pid:$start"
}
opb_request_init() {
    printf '%s:%s:%s\n' "$(opb_boot_id)" "$$" "$(opb_uptime)" > "$MODDIR/init.request.$$" &&
        mv -f "$MODDIR/init.request.$$" "$MODDIR/init.request"
}
opb_init_status() {
    echo "timestamp=$(date +%s) event=$OPB_INIT_KEY state=$1 bad_samples=${OPB_INIT_BAD:-0} attempts=${OPB_INIT_ATTEMPTED:-0}" > "$MODDIR/init.status.tmp"
    mv -f "$MODDIR/init.status.tmp" "$MODDIR/init.status"
}
opb_run_event_repair() {
    sh "$MODDIR/repair-wifi.sh" --event "$1" 9>&- >/dev/null 2>&1
}
opb_lifecycle_step() {
    local epoch key now state rc
    epoch="$(opb_framework_epoch)" || return 0
    key="$(printf '%s|%s' "$epoch" "$(cat "$MODDIR/init.request" 2>/dev/null)" | cksum | awk '{print $1}')"
    now="$(opb_uptime)"
    if [ "${OPB_INIT_KEY:-}" != "$key" ]; then
        OPB_INIT_KEY="$key" OPB_INIT_SINCE="$now" OPB_INIT_BAD=0 OPB_INIT_ATTEMPTED=0 OPB_INIT_DONE=0
        opb_init_status settling
    fi
    [ "$OPB_INIT_DONE" = 0 ] || return 0
    if [ $((now - OPB_INIT_SINCE)) -gt 180 ]; then
        opb_init_status window_closed
        OPB_INIT_DONE=1
        return 0
    fi
    [ $((now - OPB_INIT_SINCE)) -ge 20 ] || return 0
    opb_read_connection
    case "$OPB_LINK_STATE" in
        wifi_off|hotspot_active|unknown|connected_band_unknown)
            OPB_INIT_BAD=0; opb_init_status deferred; return 0 ;;
        connected_6ghz) OPB_INIT_BAD=0; opb_init_status healthy; return 0 ;;
    esac
    state="$(get_6ghz_channel_state)"
    case "$state" in
        enabled) OPB_INIT_BAD=0; opb_init_status healthy; return 0 ;;
        absent|disabled) OPB_INIT_BAD=$((OPB_INIT_BAD + 1)) ;;
        *) OPB_INIT_BAD=0; opb_init_status observation_unknown; return 0 ;;
    esac
    opb_init_status capability_check_pending
    [ "$OPB_INIT_BAD" -ge 3 ] || return 0
    rc=0; opb_run_event_repair "$key" || rc=$?
    if [ "$rc" = 75 ]; then opb_init_status deferred; return 0; fi
    OPB_INIT_ATTEMPTED=1 OPB_INIT_DONE=1
    if [ "$rc" = 0 ]; then opb_init_status completed; else opb_init_status manual_check_recommended; fi
}
opb_ensure_cfg_mounts() {
    local overlay target source_id target_id found=0
    [ -r "$MODDIR/xml/overlays.list" ] || return 1
    while IFS='|' read -r overlay target; do
        case "$overlay" in cfg_*.ini) ;; *) return 1 ;; esac
        case "$overlay" in */*) return 1 ;; esac
        case "$target" in /odm/*|/vendor/*|/mnt/vendor/persist/wlan/*) ;; *) return 1 ;; esac
        [ -f "$MODDIR/xml/$overlay" ] && [ ! -L "$MODDIR/xml/$overlay" ] || return 1
        source_id="$(stat -Lc '%d:%i' "$MODDIR/xml/$overlay")" || return 1
        target_id="$(nsenter -t 1 -m -- stat -Lc '%d:%i' "$target")" || return 1
        if [ "$source_id" != "$target_id" ]; then
            nsenter -t 1 -m -- mount -o bind "$MODDIR/xml/$overlay" "$target" || return 1
        fi
        [ "$target" != /mnt/vendor/persist/wlan/WCNSS_qcom_cfg.ini ] || found=1
    done < "$MODDIR/xml/overlays.list"
    [ "$found" = 1 ]
}
opb_repair_country() {
    local cc
    cc="$(opb_getprop persist.sys.opb.wifi.hard_unlock_country)"
    case "$cc" in [A-Z][A-Z]) ;; *) cc=US ;; esac
    opb_resetprop -n ro.boot.wificountrycode "$cc"
    opb_resetprop persist.vendor.wifi.country_code "$cc"
    opb_resetprop persist.sys.wifi.country_code "$cc"
    opb_resetprop vendor.wifi.country_code "$cc"
    opb_wifi_cmd force-country-code enabled "$cc" >/dev/null 2>&1
}
opb_repair_once() (
    local source="$1" event="$2" state rc=0 last_boot last_time last_event now boot
    exec 8> "$MODDIR/driver-repair.lock"
    flock -n 8 8>&8 || { echo 'Repair is in progress, please check the results later.'; exit 75; }
    [ ! -f "$MODDIR/disable" ] && [ ! -f "$MODDIR/remove" ] || exit 1
    opb_driver_reload_supported || { echo 'The current device has not passed the manufacturer driver repair check'; exit 1; }
    opb_read_connection
    [ "$OPB_LINK_STATE" != connected_6ghz ] || { echo 'Current connection is already on 6GHz, no repair needed.'; exit 0; }
    case "$OPB_LINK_STATE" in wifi_off|hotspot_active|unknown|connected_band_unknown)
        echo 'Wi-Fi is off, a hotspot is in use, or the status is unknown; the network connection will not be interrupted at this time'; exit 75 ;;
    esac
    state="$(get_6ghz_channel_state)"
    case "$state" in
        enabled) echo '6GHz drive capability is normal, no reload needed. No 6GHz hotspots in the vicinity will trigger repair.'; exit 0 ;;
        absent|disabled) ;;
        *) echo 'Unable to confirm driver status, not executing reload.'; exit 75 ;;
    esac
    now="$(opb_uptime)"; boot="$(opb_boot_id)"
    last_boot='' last_time=0 last_event=''
    if [ -r "$MODDIR/driver-repair.last" ]; then read -r last_boot last_time last_event < "$MODDIR/driver-repair.last"; fi
    case "$last_time" in ''|*[!0-9]*) last_time=0 ;; esac
    if [ "$source" = lifecycle ] && [ "$last_boot" = "$boot" ]; then
        [ "$last_event" != "$event" ] || { echo 'This event has already been attempted, not reloading again.'; exit 1; }
        [ $((now - last_time)) -ge 120 ] || exit 75
    fi

    echo "$boot $now $event" > "$MODDIR/driver-repair.last.tmp" &&
        mv -f "$MODDIR/driver-repair.last.tmp" "$MODDIR/driver-repair.last" || exit 1
    echo "source=$source event=$event state=repairing" > "$MODDIR/driver-init.status"
    echo 'Restoring 6GHz configuration and country code; the driver may be reloaded if necessary, which could cause a brief interruption to Wi-Fi'
    opb_ensure_cfg_mounts || { echo "source=$source state=overlay_failed" > "$MODDIR/driver-init.status"; exit 1; }
    opb_probe_wifi_commands
    RESETPROP="$(opb_find_resetprop)"
    opb_repair_country || :
    sleep 3
    state="$(get_6ghz_channel_state)"
    if [ "$state" != enabled ]; then
        if opb_driver_reload_eligible; then
            opb_reload_vendor_driver || rc=$?
            sleep 5
            if [ "$(get_6ghz_channel_state)" = disabled ]; then opb_repair_country || :; sleep 3; fi
        else rc=1; fi
    fi
    state="$(get_6ghz_channel_state)"
    [ "$state" = enabled ] || rc=1
    echo "source=$source event=$event reload_rc=$rc six_ghz=$state" > "$MODDIR/driver-init.status"
    cat "$MODDIR/driver-init.status"
    if [ "$rc" = 0 ]; then echo '6GHz drive capability has been restored; connection is determined by the system'; else echo 'This repair attempt was unsuccessful; automatic retries have been stopped'; fi
    exit "$rc"
)
