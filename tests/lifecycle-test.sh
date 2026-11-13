#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/.."
. ./wifi-lifecycle.sh
WORK="$(mktemp -d)"; MODDIR="$WORK"
echo "Lifecycle fixtures: $WORK"
assert_eq() { [ "$1" = "$2" ] || { echo "FAIL: $3 ($1 != $2)"; exit 1; }; }
opb_framework_epoch() { echo "$EPOCH"; }
opb_uptime() { echo "$NOW"; }
opb_read_connection() { OPB_LINK_STATE="$LINK"; }
get_6ghz_channel_state() { echo "$CAP"; }
opb_run_event_repair() { CALLS=$((CALLS + 1)); return "$REPAIR_RC"; }
opb_init_status() { STATUS="$1"; }
EPOCH=boot1-server1 NOW=0 LINK=connected_other_band CAP=enabled CALLS=0 REPAIR_RC=0
for NOW in 0 15 30 45 60 90 120 180 195 240; do opb_lifecycle_step; done
assert_eq "$CALLS" 0 'healthy 5 GHz/no AP never repaired'
CAP=absent
NOW=260; opb_lifecycle_step
assert_eq "$CALLS" 0 'band loss after window does not re-arm repair'
EPOCH=boot1-server2
NOW=300; opb_lifecycle_step
NOW=315; opb_lifecycle_step
assert_eq "$CALLS" 0 'framework restart settles before repair'
NOW=330; opb_lifecycle_step
NOW=345; opb_lifecycle_step
assert_eq "$CALLS" 0 'three abnormal observations required'
NOW=360; opb_lifecycle_step
assert_eq "$CALLS" 1 'framework restart handles a confirmed capability fault'
for NOW in 375 390 420 480 600; do opb_lifecycle_step; done
assert_eq "$CALLS" 1 'no repeated repair in same event'
echo module-reload > "$MODDIR/init.request"
REPAIR_RC=1
for NOW in 610 640 655 670 685 700 900; do opb_lifecycle_step; done
assert_eq "$CALLS" 2 'module reload starts one new check and failed repair never loops'
for LINK in wifi_off hotspot_active unknown connected_band_unknown connected_6ghz; do
    EPOCH="$EPOCH-next"
    for NOW in 1000 1030 1045 1060 1080 1190; do opb_lifecycle_step; done
done
assert_eq "$CALLS" 2 'respect off/hotspot/unknown/working 6 GHz'
LINK=connected_other_band CAP=unknown EPOCH=unknown
for NOW in 1200 1230 1245 1260 1390; do opb_lifecycle_step; done
assert_eq "$CALLS" 2 'failed PHY query is not a fault'
CAP=disabled EPOCH=busy REPAIR_RC=75
for NOW in 1400 1430 1445 1460 1590 1600; do opb_lifecycle_step; done
before="$CALLS"
NOW=1700; opb_lifecycle_step
assert_eq "$CALLS" "$before" 'busy deferral cannot extend event window'

# Exercise the actual repair transaction, mocking only OS operations.
opb_boot_id() { echo boot1; }
opb_driver_reload_supported() { return 0; }
opb_driver_reload_eligible() { return 0; }
opb_probe_wifi_commands() { :; }
opb_find_resetprop() { echo resetprop; }
opb_ensure_cfg_mounts() { echo mount >> "$WORK/mutations"; }
opb_repair_country() {
    echo country >> "$WORK/mutations"
    [ "$COUNTRY_FIXES" = 0 ] || echo enabled > "$WORK/cap"
}
opb_reload_vendor_driver() { echo reload >> "$WORK/mutations"; echo enabled > "$WORK/cap"; return 0; }
get_6ghz_channel_state() { cat "$WORK/cap"; }
flock() { return "$LOCK_RC"; }
sleep() { :; }
LOCK_RC=0 COUNTRY_FIXES=0 NOW=2000 LINK=connected_other_band
echo enabled > "$WORK/cap"
opb_repair_once manual first > "$WORK/result"
[ ! -e "$WORK/mutations" ]
echo absent > "$WORK/cap"
opb_repair_once lifecycle 101 > "$WORK/result"
assert_eq "$(grep -c '^reload$' "$WORK/mutations")" 1 'one driver reload'
echo absent > "$WORK/cap"
if opb_repair_once lifecycle 101 > "$WORK/result"; then echo 'FAIL: repeated event'; exit 1; fi
if opb_repair_once lifecycle 102 > "$WORK/result"; then echo 'FAIL: missing cross-event cooldown'; exit 1; else assert_eq "$?" 75 cooldown; fi
NOW=2200 COUNTRY_FIXES=1
opb_repair_once lifecycle 102 > "$WORK/result"
assert_eq "$(grep -c '^reload$' "$WORK/mutations")" 1 'country-only recovery avoids driver reload'
LOCK_RC=75
if opb_repair_once manual 103 > "$WORK/result"; then echo 'FAIL: lock ignored'; exit 1; else assert_eq "$?" 75 lock; fi
LOCK_RC=0
for LINK in wifi_off hotspot_active unknown connected_band_unknown; do
    echo absent > "$WORK/cap"
    if opb_repair_once manual 104 > "$WORK/result"; then echo 'FAIL: unsafe link state'; exit 1; else assert_eq "$?" 75 "$LINK"; fi
done
assert_eq "$(grep -c '^reload$' "$WORK/mutations")" 1 'unsafe states never reload'
LINK=connected_other_band COUNTRY_FIXES=0 NOW=2500
opb_reload_vendor_driver() { echo failed-reload >> "$WORK/mutations"; return 1; }
if opb_repair_once lifecycle 105 > "$WORK/result"; then echo 'FAIL: failed driver repair reported success'; exit 1; fi
grep -q 'reload_rc=1 six_ghz=absent' "$MODDIR/driver-init.status"
NOW=2700
if opb_repair_once lifecycle 105 > "$WORK/result"; then echo 'FAIL: failed attempt was not persisted'; exit 1; fi
assert_eq "$(grep -c '^failed-reload$' "$WORK/mutations")" 1 'failed transaction cannot repeat in same event'
echo 'PASS: lifecycle windows, debounce, once-per-event, reload, cooldown, country-only repair and mutual exclusion'
