#!/system/bin/sh

# Shared by installation, early boot and both runtime loops. No work on source.
opb_getprop() {
    # KernelSU installers may have a different PATH from an interactive shell.
    if [ -x /system/bin/getprop ]; then
        /system/bin/getprop "$1" 2>/dev/null || :
    else
        getprop "$1" 2>/dev/null || :
    fi
}

opb_detect_target() {
    local part value brands names socs platform
    OPB_BRANDS=""
    OPB_SOC="$(opb_getprop ro.soc.manufacturer)"
    OPB_SOC_MODEL="$(opb_getprop ro.soc.model)"
    OPB_HARDWARE="$(opb_getprop ro.hardware) $(opb_getprop ro.boot.hardware)"
    for part in ro.product ro.product.vendor ro.product.odm ro.product.system ro.product.product; do
        for value in "$(opb_getprop "$part.brand")" "$(opb_getprop "$part.manufacturer")"; do
            [ -n "$value" ] && OPB_BRANDS="${OPB_BRANDS}${OPB_BRANDS:+ / }$value"
        done
    done
    brands="$(printf '%s' "$OPB_BRANDS" | tr '[:upper:]' '[:lower:]')"
    names="$(opb_getprop ro.product.model) $(opb_getprop ro.product.marketname) $(opb_getprop ro.vendor.oplus.market.name)"
    names="$(printf '%s' "$names" | tr '[:upper:]' '[:lower:]')"
    socs="$(printf '%s' "$OPB_SOC $OPB_SOC_MODEL $OPB_HARDWARE" | tr '[:upper:]' '[:lower:]')"
    OPB_DEVICE_MATCH=unverified
    OPB_DEVICE_REASON="device properties incomplete or unrecognized"

    # Reject positive evidence of another SoC, not an unfamiliar spelling.
    case "$socs" in
        *mediatek*|*mtk*|*exynos*|*unisoc*|*spreadtrum*|*kirin*)
            OPB_DEVICE_MATCH=unsupported
            OPB_DEVICE_REASON="non-Qualcomm SoC: $OPB_SOC $OPB_SOC_MODEL"
            return 0
            ;;
    esac
    platform=unknown
    case "$socs" in *qualcomm*|*qcom*|*qti*|*snapdragon*) platform=qualcomm ;; esac
    case "$(printf '%s' "$OPB_SOC_MODEL" | tr '[:upper:]' '[:lower:]')" in
        sm[0-9]*|msm[0-9]*|sdm[0-9]*) platform=qualcomm ;;
        mt[0-9]*)
            OPB_DEVICE_MATCH=unsupported
            OPB_DEVICE_REASON="non-Qualcomm SoC model: $OPB_SOC_MODEL"
            return 0
            ;;
    esac
    case "$brands $names" in
        *oneplus*|*oppo*)
            if [ "$platform" = qualcomm ]; then
                OPB_DEVICE_MATCH=supported
                OPB_DEVICE_REASON="OnePlus/OPPO with Qualcomm identifiers"
            else
                OPB_DEVICE_REASON="OnePlus/OPPO detected; SoC properties unavailable or unrecognized"
            fi
            ;;
        *)
            # AOSP/GSI and missing installer properties are not proof of a mismatch.
            case "$brands" in
                *google*|*samsung*|*xiaomi*|*redmi*|*poco*|*huawei*|*honor*|*motorola*|*sony*)
                    OPB_DEVICE_MATCH=unsupported
                    OPB_DEVICE_REASON="non-OnePlus/OPPO brand: $OPB_BRANDS"
                    ;;
            esac
            ;;
    esac
    return 0
}

opb_detect_platform() {
    OPB_ANDROID="$(opb_getprop ro.build.version.release)"
    OPB_SDK="$(opb_getprop ro.build.version.sdk)"
    OPB_KERNEL="$(uname -r)"
    OPB_PAGE_SIZE="$(getconf PAGESIZE 2>/dev/null)"
    OPB_MODEL="$(opb_getprop ro.product.model)"
    opb_detect_target
    OPB_PROFILE="oneplus-qualcomm"
    [ "$OPB_DEVICE_MATCH" = supported ] || OPB_PROFILE="$OPB_DEVICE_MATCH"
    local names
    names="$(printf '%s' "$OPB_MODEL $(opb_getprop ro.product.marketname) $(opb_getprop ro.vendor.oplus.market.name)" | tr '[:upper:]' '[:lower:]' | tr -d ' _-')"
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
    opb_detect_target
    # Missing metadata must not abort installation or silently stop runtime.
    [ "$OPB_DEVICE_MATCH" != unsupported ]
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
        echo "device_match=$OPB_DEVICE_MATCH"
        echo "device_reason=$OPB_DEVICE_REASON"
        echo "brands=$OPB_BRANDS"
        echo "soc_manufacturer=$OPB_SOC"
        echo "soc_model=$OPB_SOC_MODEL"
        echo "hardware=$OPB_HARDWARE"
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

opb_parse_reg_country() {
    awk -v wanted="phy#$1" '
        /^global/ { scope="global" }
        /^phy#/ { scope=$1 }
        $1 == "country" && scope == wanted {
            sub(/:$/, "", $2); print $2; found=1; exit
        }
        END { if (!found) print "unknown" }
    '
}

opb_get_reg_country() {
    local iface phy
    iface="$(opb_getprop wifi.interface)"
    iface="${iface:-wlan0}"
    phy="$(cat "/sys/class/net/$iface/phy80211/index" 2>/dev/null)"
    case "$phy" in ''|*[!0-9]*) echo unknown; return ;; esac
    iw reg get 2>/dev/null | opb_parse_reg_country "$phy"
}

opb_has_driver_reload_service() {
    awk '$1 == "service" && $2 == "wifiDriverReload" && $3 == "/odm/bin/wlan_ko_insmod.sh" && NF == 3 {found=1} END {exit !found}'
}

opb_driver_reload_files_present() {
    [ -f /odm/bin/wlan_ko_insmod.sh ] || { OPB_RELOAD_REASON=vendor_script_missing; return 1; }
    [ -f /vendor/lib/modules/qca_cld3_peach_v2.ko ] || { OPB_RELOAD_REASON=driver_file_missing; return 1; }
    opb_has_driver_reload_service < /odm/etc/init/init.vendor.oplus.connectivity.rc 2>/dev/null || {
        OPB_RELOAD_REASON=service_declaration_missing; return 1;
    }
}

opb_driver_module_loaded() { [ -d /sys/module/qca_cld3_peach_v2 ]; }

opb_driver_reload_supported() {
    # Service state can be unset after boot. Verify the OEM declaration instead
    # of mistaking an unpublished init.svc property for an unsupported device.
    OPB_RELOAD_REASON=unknown
    OPB_RELOAD_SERVICE="$(opb_getprop init.svc.wifiDriverReload)"
    [ "$(opb_getprop ro.product.model)" = PLK110 ] || { OPB_RELOAD_REASON=model_mismatch; return 1; }
    [ "$(opb_getprop ro.soc.model)" = SM8850 ] || { OPB_RELOAD_REASON=soc_mismatch; return 1; }
    opb_driver_reload_files_present || return 1
    case "$OPB_RELOAD_SERVICE" in
        ''|stopped) ;;
        running|restarting) OPB_RELOAD_REASON=service_busy; return 75 ;;
        *) OPB_RELOAD_REASON=service_state_unknown; return 75 ;;
    esac
    opb_driver_module_loaded || { OPB_RELOAD_REASON=driver_not_loaded; return 75; }
    OPB_RELOAD_REASON=ready
    return 0
}

opb_driver_reload_eligible() {
    opb_driver_reload_supported || return 1
    case "$(get_6ghz_channel_state)" in absent|disabled) ;; *) return 1 ;; esac
    # Require our overlay on the actual firmware search path in init's namespace.
    grep -F '/oneplus_global_wifi_beast/xml/' /proc/1/mountinfo 2>/dev/null |
        grep -Fq ' /mnt/vendor/persist/wlan/WCNSS_qcom_cfg.ini ' || return 1
    return 0
}

opb_reload_vendor_driver() (
    # Restore Wi-Fi on normal completion and on an unsuccessful reload request.
    trap 'opb_set_wifi_enabled enabled >/dev/null 2>&1' EXIT
    trap 'exit 1' INT TERM
    opb_set_wifi_enabled disabled >/dev/null 2>&1 || exit 1
    sleep 3
    setprop ctl.start wifiDriverReload || exit 1
    sleep 3
    n=0
    while [ "$n" -lt 20 ]; do
        case "$(opb_getprop init.svc.wifiDriverReload)" in
            stopped) exit 0 ;;
            ''|running|restarting) ;;
            *) exit 1 ;;
        esac
        sleep 1
        n=$((n + 1))
    done
    exit 1
)
