#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/.."
. ./compat.sh
. ./wifi-policy.sh
assert_eq() { [ "$1" = "$2" ] || { echo "FAIL: $3: $1 != $2" >&2; exit 1; }; }
WORK="$(mktemp -d)"
echo "Policy fixtures: $WORK"
SCAN_OTHER='aa:bb:cc:dd:ee:ff 5180 -40 2.000 office [WPA3]'
SCAN_SIX='aa:bb:cc:dd:ee:ff 6935 -89 2.000 office [WPA3]'
assert_eq "$(printf '%s\n' "$SCAN_SIX" | opb_parse_scan_cache)" visible 'fresh weak 6 GHz AP'
assert_eq "$(printf '%s\n' "$SCAN_OTHER" | opb_parse_scan_cache)" not_seen_in_recent_cache 'fresh other-band AP'
assert_eq "$(printf 'aa:bb:cc:dd:ee:ff 6935 -40 90.000 stale\n' | opb_parse_scan_cache)" unknown 'stale result'
assert_eq "$(printf 'aa:bb:cc:dd:ee:ff 6935 -40 ___?___ bad-age\n' | opb_parse_scan_cache)" unknown 'unknown age'
assert_eq "$(printf 'invalid-mac 6935 -40 1.000 junk\n' | opb_parse_scan_cache)" unknown 'invalid table'
assert_eq "$(printf '' | opb_parse_scan_cache)" unknown 'empty cache is inconclusive'

for link in connected_other_band connected_6ghz connected_band_unknown wifi_off hotspot_active; do
    for cap in enabled disabled absent unknown; do
        assert_eq "$(opb_classify_wifi "$link" "$cap" visible 99)" "$link" 'preserve link/user state over any capability report'
    done
done
assert_eq "$(opb_classify_wifi disconnected enabled visible 0)" waiting_for_system_selection 'visible AP is not a reconnect order'
assert_eq "$(opb_classify_wifi disconnected enabled not_seen_in_recent_cache 0)" no_recent_6ghz_seen 'no visible AP is not a failure'
assert_eq "$(opb_classify_wifi disconnected enabled unknown 0)" waiting_for_scan_cache 'missing scan data'
assert_eq "$(opb_classify_wifi disconnected absent visible 2)" capability_check_pending 'debounce capability observations'
assert_eq "$(opb_classify_wifi disconnected absent visible 3)" manual_check_recommended 'confirmed fault only suggests manual action'

# Exercise real observation loops, allowing only explicitly read-only commands.
getprop() { :; }
settings() {
    [ "$*" = 'get global wifi_on' ] || { echo "settings $*" >> "$WORK/forbidden"; return 1; }
    echo "$WIFI_ON"
}
iw() {
    case "$*" in
        dev) printf 'phy#2\n Interface wlan0\n type %s\n' "$IFACE_TYPE" ;;
        'dev wlan0 link') printf '%s\n' "$LINK_DUMP"; return "$LINK_RC" ;;
        phy) printf '%s\n' "$PHY_DUMP"; return "$PHY_RC" ;;
        *) echo "iw $*" >> "$WORK/forbidden"; return 1 ;;
    esac
}
opb_wifi_cmd() {
    [ "$*" = list-scan-results ] || { echo "cmd wifi $*" >> "$WORK/forbidden"; return 1; }
    printf '%s\n' "$SCAN_DUMP"
}
opb_set_wifi_enabled() { echo 'wifi toggle' >> "$WORK/forbidden"; }
opb_reload_vendor_driver() { echo 'driver reload' >> "$WORK/forbidden"; }
wpa_cli() { echo 'reassociate' >> "$WORK/forbidden"; }
setprop() { echo "setprop $*" >> "$WORK/forbidden"; }
WIFI_ON=1 IFACE_TYPE=managed LINK_RC=0 PHY_RC=0
PHY_DUMP='Wiphy phy2
  * 5180.0 MHz [36] (23.0 dBm)'
LINK_DUMP='Connected to aa:bb:cc:dd:ee:ff
  freq: 5180.0
  signal: -90 dBm
  tx bitrate: 6.0 MBit/s'
SCAN_DUMP="$SCAN_SIX"
OPB_BAD_SAMPLES=0
n=0
while [ "$n" -lt 12 ]; do
    opb_monitor_step
    assert_eq "$OPB_POLICY_ACTION" keep_connection 'weak 5 GHz link preserved, even with nearby 6 GHz'
    n=$((n+1))
done
LINK_DUMP='Not connected.'
n=0
while [ "$n" -lt 12 ]; do
    opb_monitor_step
    assert_eq "$OPB_POLICY_ACTION" observe_only 'missing capability never triggers retries'
    n=$((n+1))
done
assert_eq "$OPB_POLICY_STATE" manual_check_recommended 'diagnostic after sustained fault'
PHY_DUMP='Wiphy phy2
  * 6935.0 MHz [197] (24.0 dBm)'
SCAN_DUMP="$SCAN_OTHER"
opb_monitor_step
assert_eq "$OPB_POLICY_STATE" no_recent_6ghz_seen 'no AP in recent cache'
LINK_RC=1
opb_monitor_step
assert_eq "$OPB_POLICY_STATE" observation_unknown 'failed link query'
LINK_RC=0 LINK_DUMP='Connected to aa:bb:cc:dd:ee:ff
  freq: 5180.0
  Link 1:
    freq: 6935.0'
opb_monitor_step
assert_eq "$OPB_POLICY_STATE" connected_6ghz 'MLO secondary frequency'
IFACE_TYPE=AP
opb_monitor_step
assert_eq "$OPB_POLICY_STATE" hotspot_active 'keep hotspot'
IFACE_TYPE=managed WIFI_ON=0
opb_monitor_step
assert_eq "$OPB_POLICY_STATE" wifi_off 'respect manual Wi-Fi off'
WIFI_ON=unknown LINK_DUMP='Not connected.'
opb_monitor_step
assert_eq "$OPB_POLICY_STATE" observation_unknown 'failed Wi-Fi-state query is not idle'
[ ! -e "$WORK/forbidden" ] || { cat "$WORK/forbidden"; exit 1; }

# The runtime country function must also honor a busy/unknown connection.
sed -n '/^enforce_country_runtime()/,/^set_feature_props()/ { /^set_feature_props()/!p; }' service.sh > "$WORK/country.sh"
. "$WORK/country.sh"
is_valid_cc() { echo 1; }
opb_resetprop() { echo country-write >> "$WORK/forbidden"; }
set_country_props() { echo country-write >> "$WORK/forbidden"; }
for state in connected_other_band connected_6ghz connected_band_unknown hotspot_active wifi_off unknown; do
    opb_read_connection() { OPB_LINK_STATE="$state"; }
    enforce_country_runtime US
done
[ ! -e "$WORK/forbidden" ]

# Regression guard: automatic entry points contain no disruptive call sites.
if sed '/^[[:space:]]*#/d' service.sh wifi-heartbeat.sh wifi-policy.sh post-fs-data.sh |
    grep -E 'reassociate|opb_reload_vendor_driver|opb_set_wifi_enabled|opb_initialize_driver|ctl[.]start|ctl[.]restart|start-scan|reload-resources'; then
    echo 'FAIL: disruptive automatic call site'; exit 1
fi
if sh repair-wifi.sh > "$WORK/manual-help" 2>&1; then
    echo 'FAIL: manual action needs explicit flag'; exit 1
fi
grep -q 'Manual repair only' "$WORK/manual-help"
echo 'PASS: passive state classification, stale cache, weak links, MLO, hotspot, Wi-Fi off, repeated observations and no disruptive calls'
