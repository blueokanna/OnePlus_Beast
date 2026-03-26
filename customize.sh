#!/system/bin/sh

REPLACE="
"

WIFICFG="WCNSS_qcom_cfg.ini"
XMLDIR="${MODPATH}/xml"
TARGET_CC="US"

ui_print "- OnePlus Beast customize: preparing Wi-Fi cfg patches"
mkdir -p "${XMLDIR}"

set_or_append() {
	local file="$1"
	local key="$2"
	local value="$3"
	if grep -q "^${key}=" "$file"; then
		sed -i "s@^${key}=.*@${key}=${value}@g" "$file"
	else
		echo "${key}=${value}" >> "$file"
	fi
}

patch_cfg_file() {
	local f="$1"
	[ -f "$f" ] || return 0

	sed -i 's@BandCapability=@#BandCapabilityMOD=@g' "$f"
	sed -i 's@enable_11be=0@enable_11be=1@g' "$f"
	sed -i 's@enable_eht=0@enable_eht=1@g' "$f"
	sed -i 's@gEnableMlo=0@gEnableMlo=1@g' "$f"
	sed -i 's@gMloSupportEnabled=0@gMloSupportEnabled=1@g' "$f"

	# Core behavior aligned with AndroPlus approach + OnePlus Beast profile.
	set_or_append "$f" "gCountryCodePriority" "1"
	set_or_append "$f" "gOemForceCountryCode" "$TARGET_CC"
	set_or_append "$f" "gEnable6Ghz" "1"
	set_or_append "$f" "gEnable6GHzBand" "1"
	set_or_append "$f" "gEnable6GHzPsc" "1"
	set_or_append "$f" "gEnable6GHzReducedScan" "0"
	set_or_append "$f" "gSoftap6gEnable" "1"
	set_or_append "$f" "gEnable6GhzSap" "1"
	set_or_append "$f" "g11beSupportEnabled" "1"
	set_or_append "$f" "gEnable11be" "1"
	set_or_append "$f" "gEhtSupportEnabled" "1"
	set_or_append "$f" "gEnableEht" "1"
	set_or_append "$f" "gEnableMlo" "1"
	set_or_append "$f" "gMloSupportEnabled" "1"
	set_or_append "$f" "gMloStaSupport" "1"
	set_or_append "$f" "gMloSapSupport" "1"
	set_or_append "$f" "gMloMaxLinkCount" "2"
	set_or_append "$f" "gEnableDBS" "1"
	set_or_append "$f" "gEnableBridgedSoftAp" "1"
	set_or_append "$f" "gEnableAcs" "1"
	set_or_append "$f" "gAcsWithMoreParam" "1"
	set_or_append "$f" "gStaPrefer6GHz" "1"

	# JP channel compatibility + AU 1000mW style power cap (with health-aware runtime derating).
	set_or_append "$f" "gEnableChannel144" "1"
	set_or_append "$f" "gEnableJapanChannel14" "1"
	set_or_append "$f" "gStaTxPowerMaxDbm" "30"
	set_or_append "$f" "gSapTxPowerMaxDbm" "30"
	set_or_append "$f" "g6gTxPowerMaxDbm" "30"
}

if [ -e "/odm/vendor/etc/wifi/${WIFICFG}" ]; then
	ui_print "  - Found /odm/vendor/etc/wifi/${WIFICFG}"
	cp -af "/odm/vendor/etc/wifi/${WIFICFG}" "${XMLDIR}/${WIFICFG}"
	patch_cfg_file "${XMLDIR}/${WIFICFG}"
elif [ -e "/vendor/etc/wifi/${WIFICFG}" ]; then
	ui_print "  - Found /vendor/etc/wifi/${WIFICFG}"
	cp -af "/vendor/etc/wifi/${WIFICFG}" "${XMLDIR}/${WIFICFG}"
	patch_cfg_file "${XMLDIR}/${WIFICFG}"
else
	ui_print "  - WCNSS cfg not found under odm/vendor, skip xml mirror"
fi


if [ -e "/mnt/vendor/persist/wlan/${WIFICFG}" ]; then
	ui_print "  - Patching /mnt/vendor/persist/wlan/${WIFICFG}"
	patch_cfg_file "/mnt/vendor/persist/wlan/${WIFICFG}"
fi

ui_print "- customize done (no system partition file was modified)"