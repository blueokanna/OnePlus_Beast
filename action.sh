#!/system/bin/sh
# Native KernelSU/Magisk module-card Action button.
MODDIR=${0%/*}
[ "$MODDIR" != "$0" ] || MODDIR=.
echo 'OnePlus Beast · Check and Repair 6GHz'
exec sh "$MODDIR/repair-wifi.sh" --reload-driver
