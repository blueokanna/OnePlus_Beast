#!/system/bin/sh

# Shared by installation, early boot and both runtime loops. No work on source.
opb_detect_platform() {
    OPB_ANDROID="$(getprop ro.build.version.release)"
    OPB_SDK="$(getprop ro.build.version.sdk)"
    OPB_KERNEL="$(uname -r)"
    OPB_PAGE_SIZE="$(getconf PAGESIZE 2>/dev/null)"
    OPB_MODEL="$(getprop ro.product.model)"
    OPB_PROFILE="oneplus-qualcomm"
    local names
    names="$(printf '%s' "$OPB_MODEL $(getprop ro.product.marketname) $(getprop ro.vendor.oplus.market.name)" | tr '[:upper:]' '[:lower:]' | tr -d ' _-')"
    case "$names" in
        *oneplus15*) OPB_PROFILE="oneplus15" ;;
    esac
    # Android userspace and the kernel's ACK/KMI branch are independent.
    # Do not reject Android 17 on android16-6.12, or pin an OTA build hash.
    OPB_KERNEL_BRANCH="unknown"
    case "$OPB_KERNEL" in
        6.12.*-android16-*) OPB_KERNEL_BRANCH="android16-6.12" ;;
    esac
}

opb_is_target_device() {
    local vendor soc
    vendor="$(getprop ro.product.brand) $(getprop ro.product.manufacturer) $(getprop ro.product.vendor.brand)"
    vendor="$(printf '%s' "$vendor" | tr '[:upper:]' '[:lower:]')"
    soc="$(getprop ro.soc.manufacturer | tr '[:upper:]' '[:lower:]')"
    case "$vendor" in *oneplus*|*oppo*) ;; *) return 1 ;; esac
    case "$soc" in *qcom*|*qualcomm*|'') return 0 ;; *) return 1 ;; esac
}

opb_find_resetprop() {
    local candidate
    candidate="$(command -v resetprop 2>/dev/null)"
    [ -n "$candidate" ] && { echo "$candidate"; return; }
    for candidate in /data/adb/magisk/resetprop /data/adb/ksu/bin/resetprop /data/adb/ap/bin/resetprop; do
        [ -x "$candidate" ] && { echo "$candidate"; return; }
    done
    return 1
}

opb_resetprop() {
    if [ -n "$RESETPROP" ]; then
        "$RESETPROP" "$@"
    else
        [ "$1" = "-n" ] && shift
        # setprop cannot change ro.*; report its failure instead of claiming success.
        setprop "$@"
    fi
}

opb_cmd_wifi_raw() {
    command -v cmd >/dev/null 2>&1 || return 127
    if command -v timeout >/dev/null 2>&1; then
        timeout 5 cmd wifi "$@"
    else
        cmd wifi "$@"
    fi
}

opb_probe_wifi_commands() {
    OPB_WIFI_COMMANDS="$(opb_cmd_wifi_raw help 2>/dev/null | awk '{print $1}')"
}

opb_wifi_has_command() {
    printf '%s\n' "$OPB_WIFI_COMMANDS" | grep -Fxq "$1"
}

opb_wifi_cmd() {
    opb_wifi_has_command "$1" || return 127
    opb_cmd_wifi_raw "$@"
}

opb_set_wifi_enabled() {
    opb_wifi_cmd set-wifi-enabled "$1" && return 0
    command -v svc >/dev/null 2>&1 || return 1
    case "$1" in
        enabled) svc wifi enable ;;
        disabled) svc wifi disable ;;
        *) return 1 ;;
    esac
}

opb_write_compat_report() {
    {
        echo "profile=$OPB_PROFILE"
        echo "model=$OPB_MODEL"
        echo "android_release=$OPB_ANDROID"
        echo "android_sdk=$OPB_SDK"
        echo "kernel=$OPB_KERNEL"
        echo "kernel_branch=$OPB_KERNEL_BRANCH"
        echo "page_size=${OPB_PAGE_SIZE:-unknown}"
        echo "resetprop=${RESETPROP:-unavailable}"
        echo "iw=$(command -v iw 2>/dev/null)"
        local name
        for name in force-country-code reload-resources start-scan set-wifi-enabled; do
            if opb_wifi_has_command "$name"; then
                echo "cmd_wifi_${name}=available"
            else
                echo "cmd_wifi_${name}=unavailable"
            fi
        done
    } > "$MODDIR/compatibility.status"
}

# Discover actual files, including chipset subdirectories and symlinked configs.
# Never create an invented vendor config when a ROM does not ship one.
opb_find_cfg_sources() {
    if [ "$#" -eq 0 ]; then
        set -- /odm/vendor/etc/wifi /odm/etc/wifi /vendor/etc/wifi /vendor/firmware/wlan /mnt/vendor/persist/wlan
    fi
    local root
    for root in "$@"; do
        [ -d "$root" ] || continue
        find "$root" -name WCNSS_qcom_cfg.ini -print 2>/dev/null
    done | sort -u
}

opb_set_cfg_key() {
    local file="$1" key="$2" value="$3"
    # Qualcomm INIs can terminate at END. Insert missing keys before it, and
    # normalize duplicate/whitespace variants without touching partition files.
    awk -v key="$key" -v value="$value" '
        $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            if (!written) print key "=" value
            written = 1
            next
        }
        /^[[:space:]]*END[[:space:]]*$/ {
            if (!written) print key "=" value
            written = 1
        }
        { print }
        END { if (!written) print key "=" value }
    ' "$file" > "${file}.tmp" && cat "${file}.tmp" > "$file"
    local rc=$?
    rm -f "${file}.tmp"
    return "$rc"
}

get_6ghz_channel_state() {
    local dump
    # A denied/partial netlink dump is unknown, never proof of a lost band.
    dump="$(iw phy 2>/dev/null)" || { echo unknown; return; }
    printf '%s\n' "$dump" | awk '
        /^Wiphy / { phy_seen = 1 }
        /MHz/ {
            for (i = 1; i <= NF; i++) {
                if ($i == "MHz") {
                    freq = $(i - 1) + 0
                    if (freq >= 5925 && freq <= 7125) {
                        seen = 1
                        if ($0 !~ /disabled/) enabled = 1
                    }
                }
            }
        }
        END {
            if (!phy_seen) print "unknown"
            else if (enabled) print "enabled"
            else if (seen) print "disabled"
            else print "absent"
        }
    '
}

opb_recovery_due() {
    # Both cellular events and channel loss share the same rate limit.
    [ "$3" -gt 0 ] || return 1
    [ "$1" -eq 0 ] || [ "$2" -ge 3 ] || return 1
    [ "$4" -eq 0 ] || [ $(( $3 - $4 )) -ge "$5" ]
}
