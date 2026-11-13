#!/usr/bin/env bash
# Android commands are mocked; never changes host networking or Android files.
set -eu
cd "$(dirname "$0")/.."
ROOT="$PWD"
. ./compat.sh
WORK="$(mktemp -d)"
# Keep fixtures for inspection; the runner can remove its temporary directory.
echo "Fixtures: $WORK"
assert_eq() {
    [ "$1" = "$2" ] || { echo "FAIL: $3: expected '$2', got '$1'" >&2; exit 1; }
}
getprop() {
    case "$1" in
        ro.product.brand) echo "${TEST_BRAND:-OnePlus}" ;;
        ro.product.manufacturer) echo OnePlus ;;
        ro.soc.manufacturer) echo "${TEST_SOC:-Qualcomm}" ;;
        ro.product.model) echo 'OnePlus 15' ;;
        ro.build.version.release) echo "${TEST_ANDROID:-17}" ;;
        ro.build.version.sdk) echo 37 ;;
    esac
}
uname() { echo '6.12.69-android16-6-g5fd39602326e-ab16372235-4k'; }
getconf() { echo 4096; }
opb_detect_platform
opb_is_target_device
assert_eq "$OPB_ANDROID" 17 'userspace Android version'
assert_eq "$OPB_KERNEL_BRANCH" android16-6.12 'independent kernel branch'
assert_eq "$OPB_PROFILE" oneplus15 'OnePlus 15 profile'
assert_eq "$OPB_PAGE_SIZE" 4096 '4 KB pages'
TEST_ANDROID=16
opb_detect_platform
assert_eq "$OPB_ANDROID" 16 'older Android remains supported'
TEST_SOC=MediaTek
if opb_is_target_device; then echo 'FAIL: accepted non-Qualcomm'; exit 1; fi
unset TEST_SOC TEST_ANDROID
echo 'PASS: platform detection'

# Mock the actual executable so the timeout path is exercised too.
mkdir "$WORK/bin"
cat > "$WORK/bin/cmd" <<'EOF'
#!/bin/sh
if [ "$2" = help ]; then
    printf '  force-country-code enabled <CC>\n  set-wifi-enabled enabled|disabled\n'
else
    echo "$*" >> "$OPB_TEST_CALLS"
    exit "${OPB_TEST_CMD_RC:-0}"
fi
EOF
chmod +x "$WORK/bin/cmd"
export PATH="$WORK/bin:$PATH" OPB_TEST_CALLS="$WORK/commands"
opb_probe_wifi_commands
opb_wifi_cmd force-country-code enabled US
assert_eq "$(cat "$OPB_TEST_CALLS")" 'wifi force-country-code enabled US' 'supported command'
if opb_wifi_cmd reload-resources; then echo 'FAIL: unsupported command accepted'; exit 1; fi
assert_eq "$(wc -l < "$OPB_TEST_CALLS" | tr -d ' ')" 1 'unsupported command skipped'
svc() { echo "$*" > "$WORK/svc"; }
export OPB_TEST_CMD_RC=1
opb_set_wifi_enabled enabled
assert_eq "$(cat "$WORK/svc")" 'wifi enable' 'svc fallback after failure'
unset OPB_TEST_CMD_RC
MODDIR="$WORK" RESETPROP=""
opb_write_compat_report
grep -qx 'cmd_wifi_reload-resources=unavailable' "$WORK/compatibility.status"
echo 'PASS: command detection, fallback and report'

iw() { printf '%s\n' "$IW_DUMP"; return "${IW_RC:-0}"; }
IW_DUMP='Wiphy phy0
    * 5955 MHz [1] (23.0 dBm)'
assert_eq "$(get_6ghz_channel_state)" enabled '6 GHz enabled'
IW_DUMP='Wiphy phy0
    * 5955 MHz [1] (disabled)'
assert_eq "$(get_6ghz_channel_state)" disabled '6 GHz disabled'
IW_DUMP='Wiphy phy0
    * 5180 MHz [36] (23.0 dBm)'
assert_eq "$(get_6ghz_channel_state)" absent '6 GHz absent'
IW_RC=1
assert_eq "$(get_6ghz_channel_state)" unknown 'partial failed dump'
IW_RC=0 IW_DUMP=''
assert_eq "$(get_6ghz_channel_state)" unknown 'empty dump'
unset -f iw
echo 'PASS: PHY state and netlink failures'

mkdir -p "$WORK/vendor/wifi/chipset" "$WORK/odm/wifi"
printf '# vendor config\r\n gEnableMlo = 0\r\nEND\r\n' > "$WORK/vendor/wifi/chipset/WCNSS_qcom_cfg.ini"
printf 'gEnableMlo=0\nEND\n' > "$WORK/original.ini"
ln -s "$WORK/original.ini" "$WORK/odm/wifi/WCNSS_qcom_cfg.ini"
if [ ! -L "$WORK/odm/wifi/WCNSS_qcom_cfg.ini" ]; then
    echo 'NOTE: host emulates symlinks; real symlink case runs on Linux CI'
fi
opb_find_cfg_sources "$WORK/vendor" "$WORK/odm" > "$WORK/discovered"
assert_eq "$(wc -l < "$WORK/discovered" | tr -d ' ')" 2 'nested and linked config discovery'
cp "$WORK/vendor/wifi/chipset/WCNSS_qcom_cfg.ini" "$WORK/before.ini"
mkdir "$WORK/module"
cp compat.sh "$WORK/module/compat.sh"
# Override only discovery in the test module; run the complete real installer.
printf '\nopb_find_cfg_sources() { cat "%s/discovered"; }\n' "$WORK" >> "$WORK/module/compat.sh"
(
    MODPATH="$WORK/module"
    ui_print() { :; }
    abort() { echo "$*" >&2; exit 1; }
    set_perm() { :; }
    set_perm_recursive() { :; }
    . "$ROOT/customize.sh"
)
cmp "$WORK/vendor/wifi/chipset/WCNSS_qcom_cfg.ini" "$WORK/before.ini"
assert_eq "$(cat "$WORK/original.ini")" "$(printf 'gEnableMlo=0\nEND')" 'symlink source remains untouched'
assert_eq "$(wc -l < "$WORK/module/xml/overlays.list" | tr -d ' ')" 2 'per-file manifest'
for cfg in "$WORK/module/xml/"cfg_*.ini; do
    [ ! -L "$cfg" ]
    awk '/^END$/ { exit } { print }' "$cfg" > "$WORK/active-keys"
    grep -qx 'gEnableMlo=1' "$WORK/active-keys"
    grep -qx 'gEnable6Ghz=1' "$WORK/active-keys"
    cp "$cfg" "$WORK/first-patch"
    opb_set_cfg_key "$cfg" gEnable6Ghz 1
    cmp "$cfg" "$WORK/first-patch"
done
printf 'key = 0\nkey=2\nEND\n' > "$WORK/duplicates"
opb_set_cfg_key "$WORK/duplicates" key 1
assert_eq "$(cat "$WORK/duplicates")" "$(printf 'key=1\nEND')" 'duplicate keys'
printf '# no terminator\n' > "$WORK/no-end"
opb_set_cfg_key "$WORK/no-end" key 1
grep -qx 'key=1' "$WORK/no-end"
echo 'PASS: installer, isolated copies, END handling and idempotency'

if opb_recovery_due -1 0 100 0 60; then echo 'FAIL: boot restart'; exit 1; fi
if opb_recovery_due 0 0 130 100 60; then echo 'FAIL: radio cooldown'; exit 1; fi
if opb_recovery_due -1 3 130 100 60; then echo 'FAIL: channel cooldown'; exit 1; fi
if opb_recovery_due 0 3 0 0 60; then echo 'FAIL: invalid uptime'; exit 1; fi
opb_recovery_due 0 0 160 100 60
opb_recovery_due -1 3 160 100 60
echo 'PASS: boot behavior and shared recovery cooldown'

sed -n '/^assess_mlo_balance()/,/^rebalance_mlo_links()/ { /^rebalance_mlo_links()/!p; }' service.sh > "$WORK/mlo.sh"
. "$WORK/mlo.sh"
get_wifi_ifaces() { printf '%s\n' "$TEST_IFACES"; }
get_interface_freq_mhz() { if [ "$1" = wlan0 ]; then echo 5180; else echo 5955; fi; }
get_interface_txrate_mbps() { if [ "$1" = wlan0 ]; then echo 1200; else echo 10; fi; }
TEST_IFACES=wlan0
assert_eq "$(assess_mlo_balance)" 0 'single-netdev MLO is not stalled'
TEST_IFACES='wlan0 wlan1'
assert_eq "$(assess_mlo_balance)" 1 'visible stalled secondary link'
echo 'PASS: MLO interface handling'
echo 'All compatibility tests passed.'
