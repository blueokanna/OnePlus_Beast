#!/system/bin/sh
MODDIR=${0%/*}
[ "$MODDIR" != "$0" ] || MODDIR=.
. "$MODDIR/compat.sh"
. "$MODDIR/wifi-policy.sh"
. "$MODDIR/wifi-lifecycle.sh"
case "${1:-}" in
    --reload-driver) source=manual; event="manual-$$" ;;
    --event)
        source=lifecycle; event="${2:-}"
        case "$event" in ''|*[!0-9]*) exit 2 ;; esac ;;
    *)
        echo 'Manual repair only: sh repair-wifi.sh --reload-driver'
        echo 'This explicitly requested operation may briefly interrupt Wi-Fi.'
        exit 2 ;;
esac
[ "$(id -u)" = 0 ] || exit 1
opb_repair_once "$source" "$event"
