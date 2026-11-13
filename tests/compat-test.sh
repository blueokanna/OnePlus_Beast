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
    [ "${TEST_GETPROP_FAILURE:-0}" = 1 ] && return 127
    [ "${TEST_EMPTY_PROPS:-0}" = 1 ] && return 0
    case "$1" in
        ro.product.brand) echo "${TEST_BRAND-OnePlus}" ;;
        ro.product.manufacturer) echo "${TEST_MANUFACTURER-OnePlus}" ;;
        ro.product.vendor.manufacturer) echo "${TEST_VENDOR_MANUFACTURER-}" ;;
        ro.product.odm.brand) echo "${TEST_ODM_BRAND-}" ;;
        ro.product.system.brand) echo "${TEST_SYSTEM_BRAND-}" ;;
        ro.soc.manufacturer) echo "${TEST_SOC-Qualcomm}" ;;
        ro.soc.model) echo "${TEST_SOC_MODEL-}" ;;
        ro.hardware) echo "${TEST_HARDWARE-}" ;;
        ro.product.model) echo "${TEST_MODEL-OnePlus 15}" ;;
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

# KernelSU/property variants must not repeat v2.4's install-time rejection.
for TEST_SOC in QTI 'Qualcomm Technologies, Inc.' Snapdragon ''; do
    opb_is_target_device
done
TEST_SOC='unrecognized-vendor-string'
opb_is_target_device
assert_eq "$OPB_DEVICE_MATCH" unverified 'unfamiliar SoC is inconclusive'
TEST_SOC='' TEST_SOC_MODEL=SM8850
opb_is_target_device
assert_eq "$OPB_DEVICE_MATCH" supported 'SoC model fallback'
TEST_SOC_MODEL='' TEST_HARDWARE=qcom
opb_is_target_device
assert_eq "$OPB_DEVICE_MATCH" supported 'hardware fallback'
TEST_BRAND=aosp TEST_MANUFACTURER='' TEST_MODEL=device TEST_VENDOR_MANUFACTURER=OnePlus
opb_is_target_device
assert_eq "$OPB_DEVICE_MATCH" supported 'vendor manufacturer fallback'
TEST_VENDOR_MANUFACTURER='' TEST_ODM_BRAND=OPPO
opb_is_target_device
assert_eq "$OPB_DEVICE_MATCH" supported 'ODM brand fallback'
TEST_ODM_BRAND='' TEST_SYSTEM_BRAND=OnePlus
opb_is_target_device
assert_eq "$OPB_DEVICE_MATCH" supported 'system brand fallback'
TEST_SYSTEM_BRAND=''
opb_is_target_device
assert_eq "$OPB_DEVICE_MATCH" unverified 'generic GSI properties'
TEST_EMPTY_PROPS=1
opb_is_target_device
assert_eq "$OPB_DEVICE_MATCH" unverified 'unavailable installer properties'
unset TEST_EMPTY_PROPS
TEST_GETPROP_FAILURE=1
opb_is_target_device
assert_eq "$OPB_DEVICE_MATCH" unverified 'getprop command failure'
unset TEST_GETPROP_FAILURE
TEST_BRAND=Google TEST_MANUFACTURER=Google TEST_MODEL=Pixel
if opb_is_target_device; then echo 'FAIL: accepted known non-target brand'; exit 1; fi
unset TEST_BRAND TEST_MANUFACTURER TEST_MODEL TEST_VENDOR_MANUFACTURER TEST_ODM_BRAND TEST_SYSTEM_BRAND TEST_HARDWARE
TEST_SOC=MTK
if opb_is_target_device; then echo 'FAIL: accepted MTK'; exit 1; fi
TEST_SOC='' TEST_SOC_MODEL=MT6991
if opb_is_target_device; then echo 'FAIL: accepted MediaTek model'; exit 1; fi
unset TEST_SOC TEST_SOC_MODEL
opb_detect_platform
echo 'PASS: installer property aliases, fallbacks and explicit mismatches'

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
    TEST_SOC=QTI
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

# Exercise the actual install entry point when no device property can be read.
mkdir "$WORK/unverified-module"
cp compat.sh "$WORK/unverified-module/compat.sh"
printf '\nopb_find_cfg_sources() { :; }\n' >> "$WORK/unverified-module/compat.sh"
(
    TEST_GETPROP_FAILURE=1
    MODPATH="$WORK/unverified-module"
    ui_print() { echo "$*"; }
    abort() { echo "$*" >&2; exit 1; }
    set_perm() { :; }
    set_perm_recursive() { :; }
    . "$ROOT/customize.sh"
) > "$WORK/unverified-install.log"
grep -q 'Device check: unverified' "$WORK/unverified-install.log"
grep -q 'customize done' "$WORK/unverified-install.log"
echo 'PASS: missing properties warn without aborting the installer'

REG_DUMP='global
country 00: DFS-UNSET
phy#2 (self-managed)
country US: DFS-FCC
phy#0 (self-managed)
country 00: DFS-UNSET'
assert_eq "$(printf '%s\n' "$REG_DUMP" | opb_parse_reg_country 2)" US 'self-managed primary PHY country'
assert_eq "$(printf '%s\n' "$REG_DUMP" | opb_parse_reg_country 9)" unknown 'missing PHY is not global country'

sh tests/wifi-policy-test.sh
echo "All compatibility tests passed."
