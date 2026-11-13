#!/system/bin/sh
# Read-only observation. A missing AP, low RSSI or a 5 GHz association is not a fault.
opb_read_connection() {
    local inventory iface link freq wifi_state connected=0 unknown=0 managed=0
    OPB_LINK_STATE=unknown
    OPB_LINK_FREQ=0
    inventory="$(iw dev 2>/dev/null)" || return 0
    if printf '%s\n' "$inventory" | awk '$1=="type" && ($2=="AP" || $2=="P2P-GO") {found=1} END {exit !found}'; then
        OPB_LINK_STATE=hotspot_active
        return 0
    fi
    wifi_state="$(settings get global wifi_on 2>/dev/null)"
    if [ "$wifi_state" = 0 ]; then
        OPB_LINK_STATE=wifi_off
        return 0
    fi
    case "$wifi_state" in 1|2) ;; *) unknown=1 ;; esac
    for iface in $(printf '%s\n' "$inventory" | awk '$1=="Interface" {iface=$2} $1=="type" && $2=="managed" {print iface}'); do
        managed=1
        link="$(iw dev "$iface" link 2>/dev/null)" || { unknown=1; continue; }
        case "$link" in
            *'Connected to '*)
                connected=1
                for freq in $(printf '%s\n' "$link" | awk '$1=="freq:" {print int($2)}'); do
                    OPB_LINK_FREQ="$freq"
                    if [ "$freq" -ge 5925 ] && [ "$freq" -le 7125 ]; then
                        OPB_LINK_STATE=connected_6ghz
                        return 0
                    fi
                done
                ;;
            *'Not connected.'*) ;;
            *) unknown=1 ;;
        esac
    done
    if [ "$connected" -eq 1 ]; then
        if [ "$OPB_LINK_FREQ" -gt 0 ]; then
            OPB_LINK_STATE=connected_other_band
        else
            OPB_LINK_STATE=connected_band_unknown
        fi
    elif [ "$managed" -eq 1 ] && [ "$unknown" -eq 0 ]; then
        OPB_LINK_STATE=disconnected
    fi
}

opb_parse_scan_cache() {
    # AOSP list-scan-results: BSSID, Frequency, RSSI, Age(sec), SSID, Flags.
    # Stale/empty/unknown output cannot prove there are no 6 GHz APs nearby.
    awk '
        {
            if (split($1, mac, ":") != 6) next
            for (i=1; i<=6; i++) if (length(mac[i]) != 2 || mac[i] ~ /[^0-9a-fA-F]/) next
            if ($2 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+([.][0-9]+)?$/ || $4+0 > 60) next
            fresh=1
            if ($2+0 >= 5925 && $2+0 <= 7125) six=1
        }
        END {
            if (six) print "visible"
            else if (fresh) print "not_seen_in_recent_cache"
            else print "unknown"
        }
    '
}

opb_scan_cache_state() {
    local cache
    cache="$(opb_wifi_cmd list-scan-results 2>/dev/null)" || { echo unknown; return; }
    printf '%s\n' "$cache" | opb_parse_scan_cache
}

opb_classify_wifi() {
    # Arguments: link state, PHY capability, scan cache, consecutive bad samples.
    case "$1" in
        connected_6ghz|connected_other_band|connected_band_unknown|wifi_off|hotspot_active)
            echo "$1"; return ;;
        disconnected) ;;
        *) echo observation_unknown; return ;;
    esac
    case "$2" in
        absent|disabled)
            if [ "$4" -ge 3 ]; then echo manual_check_recommended; else echo capability_check_pending; fi
            ;;
        enabled)
            case "$3" in
                visible) echo waiting_for_system_selection ;;
                not_seen_in_recent_cache) echo no_recent_6ghz_seen ;;
                *) echo waiting_for_scan_cache ;;
            esac
            ;;
        *) echo observation_unknown ;;
    esac
}

opb_monitor_step() {
    opb_read_connection
    OPB_CHANNEL_STATE="$(get_6ghz_channel_state)"
    case "$OPB_LINK_STATE:$OPB_CHANNEL_STATE" in
        disconnected:absent|disconnected:disabled)
            OPB_BAD_SAMPLES=$((${OPB_BAD_SAMPLES:-0} + 1))
            [ "$OPB_BAD_SAMPLES" -le 3 ] || OPB_BAD_SAMPLES=3 ;;
        *) OPB_BAD_SAMPLES=0 ;;
    esac
    OPB_SCAN_STATE=unknown
    case "$OPB_LINK_STATE" in
        disconnected|connected_other_band) OPB_SCAN_STATE="$(opb_scan_cache_state)" ;;
        connected_6ghz) OPB_SCAN_STATE=connected ;;
    esac
    OPB_POLICY_STATE="$(opb_classify_wifi "$OPB_LINK_STATE" "$OPB_CHANNEL_STATE" "$OPB_SCAN_STATE" "$OPB_BAD_SAMPLES")"
    OPB_POLICY_ACTION=observe_only
    case "$OPB_LINK_STATE" in connected_*) OPB_POLICY_ACTION=keep_connection ;; esac
}
