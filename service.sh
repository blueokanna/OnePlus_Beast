#!/system/bin/sh

MODDIR=${0%/*}

. "${MODDIR}/compat.sh"
. "${MODDIR}/wifi-policy.sh"
opb_is_target_device || { log -t OnePlusBeast "$OPB_DEVICE_REASON"; exit 0; }
RESETPROP="$(opb_find_resetprop)"

until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 2
done

sleep 10

log_tag="OnePlusBeast"
logi() {
    log -t "$log_tag" "$1"
}

verify_runtime_state() {
    local cc="$1"
    local reg=""
    local forced=""
    local six=""

    forced="$(getprop persist.vendor.wifi.country_code)"
    reg="$(opb_get_reg_country)"
    six="$(get_6ghz_channel_state)"

    logi "verify target_cc=${cc} persist_cc=${forced} reg=${reg} six_ghz=${six}"
}

normalize_cc() {
    echo "$1" | tr '[:lower:]' '[:upper:]' | cut -c1-2
}

is_valid_cc() {
    case "$1" in
        [A-Z][A-Z])
            echo 1
            ;;
        *)
            echo 0
            ;;
    esac
}

get_forced_country() {
    local cc=""
    local mode="$(getprop persist.sys.opb.wifi.force_mode)"

    local hard_mode="$(getprop persist.sys.opb.wifi.hard_unlock_mode)"
    local hard_cc="$(normalize_cc "$(getprop persist.sys.opb.wifi.hard_unlock_country)")"

    # Hard unlock mode has highest priority and stays active continuously.
    if [ "$hard_mode" = "1" ] && [ "$(is_valid_cc "$hard_cc")" = "1" ]; then
        echo "$hard_cc"
        return
    fi

    # force_mode=1 enables manual country override.
    if [ "$mode" = "1" ]; then
        cc="$(normalize_cc "$(getprop persist.sys.opb.wifi.force_country_code)")"
        [ "$(is_valid_cc "$cc")" = "1" ] && echo "$cc" && return

        cc="$(normalize_cc "$(getprop persist.vendor.opb.wifi.force_country_code)")"
        [ "$(is_valid_cc "$cc")" = "1" ] && echo "$cc" && return
    fi

    echo ""
}

clamp() {
    local val="$1"
    local min="$2"
    local max="$3"
    [ "$val" -lt "$min" ] && val="$min"
    [ "$val" -gt "$max" ] && val="$max"
    echo "$val"
}

is_screen_on() {
    local state=""
    state="$(dumpsys power 2>/dev/null | awk -F= '/Display Power: state=/{print $2; exit}')"
    if [ "$state" = "ON" ]; then
        echo 1
        return
    fi

    state="$(dumpsys power 2>/dev/null | awk -F= '/mWakefulness=/{print $2; exit}')"
    case "$state" in
        Awake)
            echo 1
            ;;
        *)
            echo 0
            ;;
    esac
}

pick_dynamic_country() {
    local cc=""
    local candidate=""

    cc="$(get_forced_country)"
    [ -n "$cc" ] && echo "$cc" && return

    # Highest priority: AP-provided country from driver stack.
    for candidate in \
        "$(getprop vendor.wifi.ap_country_code)" \
        "$(getprop wlan.driver.country)" \
        "$(getprop vendor.wlan.country_code)" \
        "$(getprop vendor.wifi.country_code)" \
        "$(getprop persist.vendor.wifi.country_code)" \
        "$(getprop ro.boot.wificountrycode)"; do
        cc="$(normalize_cc "$candidate")"
        [ "$(is_valid_cc "$cc")" = "1" ] && echo "$cc" && return
    done

    # Fallback: mobile network ISO country (first MCC country in list).
    candidate="$(getprop gsm.operator.iso-country | cut -d',' -f1)"
    cc="$(normalize_cc "$candidate")"
    [ "$(is_valid_cc "$cc")" = "1" ] && echo "$cc" && return

    # Last resort from locale region.
    candidate="$(getprop persist.sys.locale | awk -F- '{print $2}')"
    cc="$(normalize_cc "$candidate")"
    [ "$(is_valid_cc "$cc")" = "1" ] && echo "$cc" && return

    # Keep world mode when country is unknown.
    echo "00"
}

set_country_props() {
    local cc="$1"
    [ "$(is_valid_cc "$cc")" = "1" ] || cc="00"
    opb_resetprop wifi.country_code "$cc"
    opb_resetprop vendor.wifi.country_code "$cc"
    opb_resetprop persist.sys.wifi.country_code "$cc"
    opb_resetprop persist.vendor.wifi.country_code "$cc"
    opb_resetprop persist.sys.wifi.default_country_code "$cc"
    opb_resetprop persist.vendor.wifi.default_country_code "$cc"
    opb_resetprop wlan.driver.country "$cc"
    opb_resetprop vendor.wlan.country_code "$cc"
    opb_resetprop vendor.wifi.ap_country_code "$cc"

    # A hard country lock must not leave a second dynamic path for telephony MCC.
    opb_resetprop persist.vendor.wifi.dynamic_regdom 0
    opb_resetprop persist.sys.wifi.dynamic_regdom 0
    opb_resetprop persist.vendor.wifi.world_mode 0
    opb_resetprop persist.vendor.wlan.global_regdom_mode 0
    opb_resetprop persist.vendor.wifi.allow_11d 0
}

enforce_country_runtime() {
    local cc="$1"
    [ "$(is_valid_cc "$cc")" = "1" ] || return 0

    opb_read_connection
    [ "$OPB_LINK_STATE" = disconnected ] || return 0

    # Apply only while all observed station links are idle.
    opb_resetprop -n ro.boot.wificountrycode "$cc"
    set_country_props "$cc"

    if command -v settings >/dev/null 2>&1; then
        settings put global wifi_country_code "$cc"
    fi

    if command -v iw >/dev/null 2>&1; then
        iw reg set "$cc" >/dev/null 2>&1
    fi

    if command -v cmd >/dev/null 2>&1; then
        opb_wifi_cmd force-country-code enabled "$cc" >/dev/null 2>&1
    fi
}

set_feature_props() {
    opb_resetprop persist.vendor.wifi.softap_6ghz_supported 1
    opb_resetprop persist.vendor.wifi.softap_6ghz_enabled 1
    opb_resetprop persist.vendor.wifi.softap.bridge_mode_supported 1
    opb_resetprop persist.vendor.wifi.wifi7_enabled 1
    opb_resetprop persist.vendor.wifi.eht_enabled 1
    opb_resetprop persist.vendor.wifi.mlo_supported 1
    opb_resetprop persist.vendor.wifi.mlo_enabled 1
    opb_resetprop persist.vendor.wifi.mlo_softap_supported 1
    opb_resetprop persist.vendor.wifi.mlo_sta_supported 1
    opb_resetprop persist.vendor.wifi.mlo_link_stats_enabled 1
    opb_resetprop persist.vendor.wifi.mlo_link_debug_visible 1
    opb_resetprop persist.sys.wifi.softap_6ghz_supported 1
    opb_resetprop persist.sys.wifi.mlo_supported 1
    opb_resetprop persist.sys.wifi.mlo_enabled 1
    opb_resetprop persist.sys.wifi.mlo_link_stats_enabled 1
    opb_resetprop persist.sys.wifi.mlo_display_fix 1
    opb_resetprop persist.sys.wifi.wifi7_profile 1
    opb_resetprop persist.sys.oplus.wifi6ghz.support 1
    opb_resetprop persist.sys.oplus.softap6ghz.support 1
    opb_resetprop persist.sys.oplus.wifi.mlo.support 1
    opb_resetprop persist.sys.oplus.wifi.mlo.display_fix 1
    opb_resetprop persist.vendor.oplus.wifi6ghz.support 1
    opb_resetprop persist.vendor.oplus.softap6ghz.support 1
    opb_resetprop persist.vendor.oplus.wifi.mlo.support 1
    opb_resetprop persist.vendor.oplus.wifi.mlo.display_fix 1
    opb_resetprop persist.vendor.wifi.dual_ap_supported 1
    opb_resetprop persist.vendor.wifi.bridged_ap_supported 1
    opb_resetprop persist.vendor.wifi.acs_supported 1
    opb_resetprop persist.vendor.wifi.dbs_supported 1
    opb_resetprop persist.vendor.wifi.multi_band_scan_supported 1
    opb_resetprop persist.vendor.wifi.txpower.dynamic_mode 1
    opb_resetprop persist.vendor.wifi.txpower.target_ratio 100
    opb_resetprop persist.vendor.wifi.txpower.balance_profile au_1000mw_safety
    opb_resetprop persist.sys.opb.txpower.max_mbm 3000
    opb_resetprop persist.sys.opb.txpower.target_ratio 100
    opb_resetprop persist.sys.opb.jp_channel_compat 1
    opb_resetprop persist.sys.opb.hotspot_6ghz_force 1
    opb_resetprop persist.sys.opb.rf_safety_mode 1
    opb_resetprop persist.vendor.wifi.allow_channel_14 1
    opb_resetprop persist.vendor.wifi.allow_channel_144 1
    opb_resetprop persist.sys.wifi.allow_channel_14 1
    opb_resetprop persist.sys.wifi.allow_channel_144 1
    opb_resetprop persist.vendor.wifi.jp_channels_compat 1
    opb_resetprop persist.vendor.wifi.rx_gain_safety_mode 1

    # WiFi8-like profile switches (best-effort, vendor support dependent).
    opb_resetprop persist.sys.opb.wifi8.mode 1
    opb_resetprop persist.sys.opb.wifi8.coordinated_twt 1
    opb_resetprop persist.sys.opb.wifi8.multi_ap_coordination 1
    opb_resetprop persist.sys.opb.wifi8.ofdma_multi_ru 1
    opb_resetprop persist.sys.opb.wifi8.dso_npca 1
    opb_resetprop persist.sys.opb.wifi8.dru_scheduler 1
    opb_resetprop persist.vendor.wifi.twt_coordinated_enabled 1
    opb_resetprop persist.vendor.wifi.multi_ap_coordination_enabled 1
    opb_resetprop persist.vendor.wifi.ofdma_multi_ru_enabled 1
    opb_resetprop persist.vendor.wifi.dso_enabled 1
    opb_resetprop persist.vendor.wifi.npca_enabled 1
    opb_resetprop persist.vendor.wifi.dru_scheduler_enabled 1
    opb_resetprop persist.vendor.wifi.ul_dl_mu_mimo_optimized 1
    opb_resetprop persist.vendor.wifi.mlo_link_aggregation_enabled 1
    opb_resetprop persist.vendor.wifi.roaming_scan_aggressive 0
    opb_resetprop persist.vendor.wifi.latency_critical_path 1
}

get_thermal_max_millic() {
    local t="0"
    local m="0"
    for z in /sys/class/thermal/thermal_zone*/temp; do
        [ -r "$z" ] || continue
        t="$(cat "$z" 2>/dev/null)"
        case "$t" in
            ''|*[!0-9]*)
                continue
                ;;
        esac
        [ "$t" -gt "$m" ] && m="$t"
    done
    echo "$m"
}

get_battery_level() {
    local lv=""
    lv="$(dumpsys battery 2>/dev/null | awk '/level:/{print $2; exit}')"
    case "$lv" in
        ''|*[!0-9]*)
            lv="50"
            ;;
    esac
    echo "$lv"
}

get_interface_rssi() {
    local iface="$1"
    local s=""
    s="$(iw dev "$iface" link 2>/dev/null | awk '/signal:/{print $2; exit}')"
    case "$s" in
        ''|*[!0-9-]*)
            s="-70"
            ;;
    esac
    echo "$s"
}

get_interface_freq_mhz() {
    local iface="$1"
    local f=""
    f="$(iw dev "$iface" link 2>/dev/null | awk '/freq:/{print $2; exit}')"
    if [ -z "$f" ]; then
        f="$(iw dev "$iface" info 2>/dev/null | sed -n 's/.*(\([0-9][0-9][0-9][0-9]\) MHz).*/\1/p' | head -n 1)"
    fi
    case "$f" in
        ''|*[!0-9]*)
            f="0"
            ;;
    esac
    echo "$f"
}

get_interface_txrate_mbps() {
    local iface="$1"
    local r=""
    r="$(iw dev "$iface" link 2>/dev/null | awk '/tx bitrate:/{print $3; exit}')"
    case "$r" in
        ''|*[!0-9.]* )
            r="0"
            ;;
    esac
    echo "${r%.*}"
}

get_interface_rxrate_mbps() {
    local iface="$1"
    local r=""
    r="$(iw dev "$iface" link 2>/dev/null | awk '/rx bitrate:/{print $3; exit}')"
    case "$r" in
        ''|*[!0-9.]* )
            r="0"
            ;;
    esac
    echo "${r%.*}"
}

band_from_freq() {
    local f="$1"
    if [ "$f" -ge 5925 ] && [ "$f" -le 7125 ]; then
        echo "6"
    elif [ "$f" -ge 4900 ] && [ "$f" -le 5895 ]; then
        echo "5"
    elif [ "$f" -ge 2400 ] && [ "$f" -le 2500 ]; then
        echo "2"
    else
        echo "5"
    fi
}

band_cap_mbm() {
    local cc="$1"
    local band="$2"
    local max_mbm="$(getprop persist.sys.opb.txpower.max_mbm)"

    case "$max_mbm" in
        ''|*[!0-9]*)
            max_mbm=3000
            ;;
    esac
    max_mbm="$(clamp "$max_mbm" 2000 3000)"

    case "$band" in
        2)
            case "$cc" in
                JP) echo "$max_mbm" ;;
                *) echo "$max_mbm" ;;
            esac
            ;;
        5)
            case "$cc" in
                JP) echo "$max_mbm" ;;
                *) echo "$max_mbm" ;;
            esac
            ;;
        6)
            case "$cc" in
                CN) echo "$max_mbm" ;;
                JP) echo "$max_mbm" ;;
                AU) echo "$max_mbm" ;;
                *) echo "$max_mbm" ;;
            esac
            ;;
        *)
            echo "$max_mbm"
            ;;
    esac
}

get_wifi_ifaces() {
    (
        iw dev 2>/dev/null | awk '$1=="Interface"{print $2}'
        for n in wlan0 wlan1 ap0 swlan0 wifi0 wifi1; do
            [ -d "/sys/class/net/$n" ] && echo "$n"
        done
    ) | awk 'NF' | sort -u
}

apply_power_save_policy() {
    local screen_on="$1"
    local iface
    for iface in $(get_wifi_ifaces); do
        if [ "$screen_on" -eq 1 ]; then
            iw dev "$iface" set power_save off >/dev/null 2>&1
        else
            iw dev "$iface" set power_save on >/dev/null 2>&1
        fi
    done
}

apply_txpower_to_iface() {
    local iface="$1"
    local cc="$2"
    local screen_on="$3"
    local freq band cap target ratio rssi temp target_ratio

    freq="$(get_interface_freq_mhz "$iface")"
    band="$(band_from_freq "$freq")"
    cap="$(band_cap_mbm "$cc" "$band")"

    # Default is AU-style 1000 mW target (3000 mBm), then apply thermal/safety derating.
    target_ratio="$(getprop persist.sys.opb.txpower.target_ratio)"
    case "$target_ratio" in
        ''|*[!0-9]*)
            target_ratio=100
            ;;
    esac
    ratio="$(clamp "$target_ratio" 70 100)"
    rssi="$(get_interface_rssi "$iface")"
    temp="$(get_thermal_max_millic)"

    # Health-oriented thermal derating for sustained RF power.
    if [ "$temp" -ge 56000 ]; then
        ratio=$((ratio - 30))
    elif [ "$temp" -ge 52000 ]; then
        ratio=$((ratio - 20))
    elif [ "$temp" -ge 48000 ]; then
        ratio=$((ratio - 10))
    fi

    if [ "$rssi" -le -78 ]; then
        ratio=$((ratio + 4))
    elif [ "$rssi" -ge -52 ]; then
        ratio=$((ratio - 6))
    fi

    # Only apply extra power saving when the screen is off.
    if [ "$screen_on" -eq 0 ]; then
        ratio=$((ratio - 8))
        if [ "$temp" -ge 48000 ]; then
            ratio=$((ratio - 4))
        fi
    fi

    ratio="$(clamp "$ratio" 70 100)"
    target=$((cap * ratio / 100))

    if [ "$target" -ge 1000 ]; then
        iw dev "$iface" set txpower limit "$target" >/dev/null 2>&1
    fi
}

apply_dynamic_txpower() {
    local cc="$1"
    local screen_on="$2"
    local iface
    for iface in $(get_wifi_ifaces); do
        apply_txpower_to_iface "$iface" "$cc" "$screen_on"
    done
}


opb_detect_platform
opb_probe_wifi_commands
opb_write_compat_report
logi "platform=$OPB_PROFILE android=$OPB_ANDROID sdk=$OPB_SDK kernel=$OPB_KERNEL page_size=$OPB_PAGE_SIZE"

# Start the watchdog only after checking the device and waiting for boot.
if [ "$(getprop persist.sys.opb.6ghz.heartbeat)" != "0" ] && \
    [ -f "${MODDIR}/wifi-heartbeat.sh" ]; then
    sh "${MODDIR}/wifi-heartbeat.sh" >/dev/null 2>&1 &
fi

# Static feature props are applied once. Never reassociate or change hotspot settings.
set_feature_props
opb_resetprop persist.vendor.wifi.roaming_scan_aggressive 0
opb_resetprop persist.vendor.wifi.mlo_rebalance_request 0
opb_resetprop persist.sys.wifi.mlo_rebalance_request 0
IDLE_SAMPLES=0
COUNTRY_ATTEMPTED=""
while true; do
    opb_read_connection
    if [ "$OPB_LINK_STATE" = disconnected ]; then
        IDLE_SAMPLES=$((IDLE_SAMPLES + 1))
    else
        IDLE_SAMPLES=0
    fi
    TARGET_CC="$(pick_dynamic_country)"
    # Country updates are deferred while any connection, AP, or uncertain state exists.
    # At most one attempt per target in this process, after three idle observations.
    if [ "$IDLE_SAMPLES" -ge 3 ] && [ "$COUNTRY_ATTEMPTED" != "$TARGET_CC" ]; then
        COUNTRY_ATTEMPTED="$TARGET_CC"
        if [ "$(opb_get_reg_country)" != "$TARGET_CC" ]; then
            enforce_country_runtime "$TARGET_CC"
        fi
    fi
    case "$OPB_LINK_STATE" in
        connected_*)
            SCREEN_ON="$(is_screen_on)"
            apply_power_save_policy "$SCREEN_ON"
            apply_dynamic_txpower "$TARGET_CC" "$SCREEN_ON"
            ;;
    esac
    sleep 15
done
