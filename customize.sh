#!/system/bin/sh

REPLACE="
"

XMLDIR="${MODPATH}/xml"
TARGET_CC="US"

. "${MODPATH}/compat.sh"
opb_detect_platform
ui_print "- Device: ${OPB_MODEL}; Android ${OPB_ANDROID} (SDK ${OPB_SDK})"
ui_print "- Kernel: ${OPB_KERNEL}; page size: ${OPB_PAGE_SIZE:-unknown}"
ui_print "- Brands: ${OPB_BRANDS:-unavailable}"
ui_print "- SoC: ${OPB_SOC:-unavailable}; model: ${OPB_SOC_MODEL:-unavailable}; hardware: ${OPB_HARDWARE}"
ui_print "- Device check: ${OPB_DEVICE_MATCH} (${OPB_DEVICE_REASON})"
case "$OPB_DEVICE_MATCH" in
    unsupported) abort "! ${OPB_DEVICE_REASON}" ;;
    unverified) ui_print "! Device metadata could not be verified; continuing with runtime capability checks" ;;
esac

ui_print "- OnePlus Beast customize: preparing Wi-Fi cfg patches"
mkdir -p "${XMLDIR}"

set_or_append() {
	local file="$1"
	local key="$2"
	local value="$3"
	opb_set_cfg_key "$file" "$key" "$value" || abort "! Failed to patch ${key}"
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
	set_or_append "$f" "g11dSupportEnabled" "0"
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

prepare_cfg_overlay() {
	local source="$1"
	local overlay="$2"

	[ -f "$source" ] && [ -r "$source" ] || return 1
	ui_print "  - Found ${source}"
	# Dereference links: cp -a could leave a link back into vendor/persist.
	[ ! -L "${XMLDIR}/${overlay}" ] || abort "! Overlay must be a regular file"
	cp -pL "$source" "${XMLDIR}/${overlay}" || abort "! Cannot copy ${source}"
	[ ! -L "${XMLDIR}/${overlay}" ] || abort "! Overlay must be a regular file"
	# Normalize CRLF before parsing END and keys.
	sed -i 's/\r$//' "${XMLDIR}/${overlay}"
	patch_cfg_file "${XMLDIR}/${overlay}"
	printf '%s|%s\n' "$overlay" "$source" >> "${XMLDIR}/overlays.list"
}

CFG_FOUND=0
: > "${XMLDIR}/overlays.list"
opb_find_cfg_sources > "${XMLDIR}/sources.list"
while IFS= read -r CFG_SOURCE; do
	# A numeric filename cannot collide across partitions or chipset directories.
	prepare_cfg_overlay "$CFG_SOURCE" "cfg_${CFG_FOUND}.ini" && CFG_FOUND=$((CFG_FOUND + 1))
done < "${XMLDIR}/sources.list"
rm -f "${XMLDIR}/sources.list"

if [ "$CFG_FOUND" -eq 0 ]; then
	ui_print "  - WCNSS cfg not found, skip cfg overlay"
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
for SCRIPT in post-fs-data.sh service.sh wifi-heartbeat.sh; do
	set_perm "$MODPATH/$SCRIPT" 0 0 0755
done

ui_print "- customize done (partition files were not modified)"
