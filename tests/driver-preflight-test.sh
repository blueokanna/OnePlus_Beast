#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/.."
. ./compat.sh
WORK="$(mktemp -d)"
assert_eq() { [ "$1" = "$2" ] || { echo "FAIL: $3 ($1 != $2)"; exit 1; }; }
printf 'service wifiDriverReload /odm/bin/wlan_ko_insmod.sh\n    disabled\n    oneshot\n' | opb_has_driver_reload_service
for declaration in '# service wifiDriverReload /odm/bin/wlan_ko_insmod.sh' 'service other /odm/bin/wlan_ko_insmod.sh' 'service wifiDriverReload /unverified/script.sh'; do
    if printf '%s\n' "$declaration" | opb_has_driver_reload_service; then echo 'FAIL: wrong service declaration'; exit 1; fi
done
opb_getprop() {
    case "$1" in
        ro.product.model) echo "$MODEL" ;;
        ro.soc.model) echo "$SOC" ;;
        init.svc.wifiDriverReload) echo "$SVC_STATE" ;;
    esac
}
opb_driver_reload_files_present() { [ "$FILES" = 1 ] || { OPB_RELOAD_REASON=service_declaration_missing; return 1; }; }
opb_driver_module_loaded() { [ "$LOADED" = 1 ]; }
MODEL=PLK110 SOC=SM8850 FILES=1 LOADED=1
for SVC_STATE in '' stopped; do
    opb_driver_reload_supported
    assert_eq "$OPB_RELOAD_REASON" ready 'unset/stopped with verified OEM service is supported'
done
for SVC_STATE in running restarting unrecognized; do
    rc=0; opb_driver_reload_supported || rc=$?
    assert_eq "$rc" 75 'busy/unknown state is deferred, not unsupported'
done
SVC_STATE='' FILES=0
rc=0; opb_driver_reload_supported || rc=$?
assert_eq "$rc" 1 'unset property alone does not authorize an unverified service'
assert_eq "$OPB_RELOAD_REASON" service_declaration_missing 'specific failure reason'
FILES=1 LOADED=0
rc=0; opb_driver_reload_supported || rc=$?
assert_eq "$rc" 75 'unloaded driver is transient'
LOADED=1 MODEL=Other
rc=0; opb_driver_reload_supported || rc=$?
assert_eq "$rc" 1 'model mismatch still rejected'
MODEL=PLK110 SOC=Other
rc=0; opb_driver_reload_supported || rc=$?
assert_eq "$rc" 1 'SoC mismatch still rejected'

# Exercise the real bounded OEM reload and its Wi-Fi restoration trap.
opb_getprop() { sed -n '1p' "$WORK/states"; sed -i '1d' "$WORK/states"; }
opb_set_wifi_enabled() { echo "$1" >> "$WORK/wifi"; }
setprop() { echo "$*" >> "$WORK/start"; }
sleep() { :; }
printf '\nrunning\nstopped\n' > "$WORK/states"
opb_reload_vendor_driver
assert_eq "$(cat "$WORK/wifi")" "$(printf 'disabled\nenabled')" 'Wi-Fi restored after delayed service publication'
assert_eq "$(cat "$WORK/start")" 'ctl.start wifiDriverReload' 'one OEM start only'
: > "$WORK/states"; : > "$WORK/wifi"; : > "$WORK/start"
rc=0; opb_reload_vendor_driver || rc=$?
assert_eq "$rc" 1 'missing completion is bounded failure'
assert_eq "$(cat "$WORK/wifi")" "$(printf 'disabled\nenabled')" 'Wi-Fi restored even on timeout'
assert_eq "$(wc -l < "$WORK/start" | tr -d ' ')" 1 'timeout never repeats the service start'
echo 'PASS: post-boot unset service state, declaration checks, busy deferral and bounded reload restoration'
