#!/system/bin/sh
# Explicit, one-shot user action. Never called by boot or background scripts.
MODDIR=${0%/*}
[ "$MODDIR" != "$0" ] || MODDIR=.
. "$MODDIR/compat.sh"
. "$MODDIR/wifi-policy.sh"
[ "${1:-}" = --reload-driver ] || {
    echo 'Manual repair only: sh repair-wifi.sh --reload-driver'
    echo 'This explicitly requested operation briefly interrupts Wi-Fi.'
    exit 2
}
[ "$(id -u)" = 0 ] || exit 1
opb_driver_reload_eligible || { echo 'No confirmed eligible driver-capability issue; no action taken.'; exit 0; }
opb_read_connection
case "$OPB_LINK_STATE" in wifi_off|hotspot_active|unknown) echo 'Wi-Fi is off, busy or unknown; no action taken.'; exit 1 ;; esac
mkdir "$MODDIR/manual-repair.lock" 2>/dev/null || { echo 'A manual repair is already running.'; exit 1; }
trap 'rmdir "$MODDIR/manual-repair.lock"' EXIT
trap 'exit 1' INT TERM
opb_probe_wifi_commands
rc=0
opb_reload_vendor_driver || rc=$?
sleep 5
state="$(get_6ghz_channel_state)"
echo "reload_rc=$rc six_ghz=$state source=manual_request" > "$MODDIR/driver-init.status"
cat "$MODDIR/driver-init.status"
exit "$rc"
