#!/bin/bash
# efx status — report what is built, what is stale and what is missing.
#
# Text output for humans, --json for the web GUI. This is the single source of
# truth for pipeline state; the GUI renders it and never recomputes it.

set -u

: "${EFX_DIR:?must be run through tools/efx/efx}"
. "$EFX_DIR/lib/common.sh"
. "$EFX_DIR/lib/conf.sh"
efx_conf_load || exit $EFX_EX_CONFIG

JSON=0
ONLY=''
PREFLIGHT=0

while [ $# -gt 0 ]; do
	case "$1" in
	--json)       JSON=1 ;;
	--preflight)  PREFLIGHT=1 ;;
	--component)  ONLY=${2:-}; shift ;;
	--component=*) ONLY=${1#*=} ;;
	-h|--help)
		echo "Usage: efx status [--json] [--component <id>] [--preflight]"
		exit 0
		;;
	*) efx_die $EFX_EX_USAGE "unknown option: $1" ;;
	esac
	shift
done

if [ $PREFLIGHT -eq 1 ]; then
	efx_preflight
	exit $?
fi

# Pipeline order, as rendered left-to-right on the dashboard.
COMPONENTS=(config fsbl opensbi uboot kernel image fpga)

label_of()
{
	case "$1" in
	config)  echo "Configuration" ;;
	fsbl)    echo "FSBL" ;;
	opensbi) echo "OpenSBI" ;;
	uboot)   echo "U-Boot" ;;
	kernel)  echo "Kernel" ;;
	image)   echo "Rootfs & Image" ;;
	fpga)    echo "FPGA / Bitstream" ;;
	esac
}

# artifacts_of <component> -> one "name<TAB>path" per line
artifacts_of()
{
	local fsbl_dir="$EFX_FSBL_DIR"

	case "$1" in
	config)
		printf '.config\t%s\n'    "$EFX_BUILD_DIR/.config"
		printf 'linux.dts\t%s\n'  "$EFX_REPO_DIR/boards/efinix/$BOARD/linux/linux.dts"
		printf 'uboot.dts\t%s\n'  "$EFX_REPO_DIR/boards/efinix/$BOARD/u-boot/uboot.dts"
		;;
	fsbl)
		printf 'bootloader.hex\t%s\n' "$fsbl_dir/bootloader.hex"
		printf 'bootloader.bin\t%s\n' "$fsbl_dir/bootloader.bin"
		printf 'bootloader.elf\t%s\n' "$fsbl_dir/bootloader.elf"
		;;
	opensbi)
		printf 'fw_jump.bin\t%s\n' "$EFX_IMAGES_DIR/fw_jump.bin"
		;;
	uboot)
		printf 'u-boot.bin\t%s\n' "$EFX_IMAGES_DIR/u-boot.bin"
		;;
	kernel)
		# What a kernel-only build actually installs. Image and uImage are made
		# by boards/efinix/common/post_build.sh, which Buildroot runs during
		# target-finalize — so they belong to the image step, not this one.
		printf 'vmlinux\t%s\n'    "$EFX_IMAGES_DIR/vmlinux"
		printf 'linux.dtb\t%s\n'  "$EFX_IMAGES_DIR/linux.dtb"
		;;
	image)
		printf 'Image\t%s\n'      "$EFX_IMAGES_DIR/Image"
		printf 'uImage\t%s\n'     "$EFX_IMAGES_DIR/uImage"
		printf 'rootfs.tar\t%s\n' "$EFX_IMAGES_DIR/rootfs.tar"
		if [ "$ROOTFS_MODE" = sdcard ]; then
			printf 'sdcard.img\t%s\n' "$EFX_IMAGES_DIR/sdcard.img"
		fi
		;;
	fpga)
		printf '%s.hex\t%s\n' "$FPGA_PROJECT" "$EFX_PROJECT_DIR/outflow/$FPGA_PROJECT.hex"
		printf '%s.bit\t%s\n' "$FPGA_PROJECT" "$EFX_PROJECT_DIR/outflow/$FPGA_PROJECT.bit"
		;;
	esac
}

# Inputs whose mtime, if newer than the artifacts, makes a component stale.
inputs_of()
{
	case "$1" in
	config)
		printf '%s\n' "$EFX_SOC_H"
		[ -n "$SOCMAP_OVERLAY" ] && printf '%s\n' "$EFX_DIR/$SOCMAP_OVERLAY"
		;;
	opensbi)
		printf '%s\n' "$EFX_REPO_DIR/boards/efinix/$BOARD/opensbi/platform.c"
		printf '%s\n' "$EFX_REPO_DIR/boards/efinix/$BOARD/opensbi/objects.mk"
		;;
	uboot)
		printf '%s\n' "$EFX_REPO_DIR/boards/efinix/common/u-boot/uboot_base_defconfig"
		printf '%s\n' "$EFX_REPO_DIR/boards/efinix/common/u-boot/uboot_${ARCH}_defconfig"
		printf '%s\n' "$EFX_REPO_DIR/boards/efinix/$BOARD/u-boot/uboot.dts"
		printf '%s\n' "$EFX_DIR/overlays/uboot_ti375_oob.cfg"
		;;
	kernel)
		printf '%s\n' "$EFX_REPO_DIR/boards/efinix/$BOARD/linux/linux.config"
		printf '%s\n' "$EFX_REPO_DIR/boards/efinix/$BOARD/linux/linux.dts"
		printf '%s\n' "$EFX_REPO_DIR/boards/efinix/common/dts/sapphire.dtsi"
		printf '%s\n' "$EFX_DIR/overlays/linux_ti375_oob.config"
		;;
	image)
		printf '%s\n' "$EFX_REPO_DIR/boards/efinix/$BOARD/genimage.cfg"
		;;
	fsbl)
		printf '%s\n' "$EFX_REPO_DIR/boards/efinix/common/bootloaderConfig.h"
		;;
	esac
}

# On-chip RAM budget for the FSBL, read straight from soc.h.
fsbl_ram_limit()
{
	local v
	v=$(efx_soc_define "$EFX_SOC_H" SYSTEM_RAM_A_SIZE)
	echo "${v:-0}"
}

# state_of_component -> missing | ok | stale | failed | cancelled | unknown
compute_state()
{
	local c=$1 recorded oldest_art=0 newest_in=0 t path name missing=0 any=0

	recorded=$(efx_state_of "$c")
	case "$recorded" in
	failed|cancelled) echo "$recorded"; return ;;
	esac

	while IFS=$'\t' read -r name path; do
		[ -n "$path" ] || continue
		any=1
		if [ -e "$path" ]; then
			t=$(efx_mtime "$path")
			if [ "$oldest_art" -eq 0 ] || [ "$t" -lt "$oldest_art" ]; then
				oldest_art=$t
			fi
		else
			missing=1
		fi
	done < <(artifacts_of "$c")

	[ $any -eq 0 ] && { echo unknown; return; }
	[ $missing -eq 1 ] && { echo missing; return; }

	while read -r path; do
		[ -n "$path" ] && [ -e "$path" ] || continue
		t=$(efx_mtime "$path")
		[ "$t" -gt "$newest_in" ] && newest_in=$t
	done < <(inputs_of "$c")

	if [ "$newest_in" -gt "$oldest_art" ]; then
		echo stale
	else
		echo ok
	fi
}

lock_busy()
{
	local pid
	pid=$(cat "$EFX_STATE_DIR/lock-pid" 2>/dev/null || true)
	[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# ------------------------------------------------------------------ output ---

emit_json()
{
	local c first=1 afirst state name path holder

	holder=$(cat "$EFX_STATE_DIR/lock-holder" 2>/dev/null || true)

	printf '{'
	printf '"generated":%s,'    "$(efx_json_str "$(date -Is)")"
	printf '"repo":%s,'         "$(efx_json_str "$EFX_REPO_DIR")"
	printf '"board":%s,'        "$(efx_json_str "$BOARD")"
	printf '"arch":%s,'         "$(efx_json_str "$ARCH")"
	printf '"soc_variant":%s,'  "$(efx_json_str "$SOC_VARIANT")"
	printf '"rootfs_mode":%s,'  "$(efx_json_str "$ROOTFS_MODE")"
	printf '"workspace":%s,'    "$(efx_json_str "$EFX_WORKSPACE_DIR")"
	printf '"images_dir":%s,'   "$(efx_json_str "$EFX_IMAGES_DIR")"
	printf '"configured":%s,'   "$([ -f "$EFX_BUILD_DIR/.config" ] && echo true || echo false)"
	printf '"free_gib":%s,'     "$(efx_free_gib "$EFX_REPO_DIR")"
	printf '"jobs":%s,'         "$EFX_JOBS"
	printf '"busy":%s,'         "$(lock_busy && echo true || echo false)"
	printf '"lock_holder":%s,'  "$(efx_json_str "$holder")"

	printf '"components":['
	for c in "${COMPONENTS[@]}"; do
		[ -n "$ONLY" ] && [ "$ONLY" != "$c" ] && continue
		[ $first -eq 1 ] || printf ','
		first=0
		state=$(compute_state "$c")

		printf '{"id":%s,"label":%s,"state":%s,' \
			"$(efx_json_str "$c")" \
			"$(efx_json_str "$(label_of "$c")")" \
			"$(efx_json_str "$state")"

		if [ -f "$EFX_STATE_DIR/last-$c.json" ]; then
			printf '"last":%s,' "$(cat "$EFX_STATE_DIR/last-$c.json")"
		else
			printf '"last":null,'
		fi

		printf '"artifacts":['
		afirst=1
		while IFS=$'\t' read -r name path; do
			[ -n "$path" ] || continue
			[ $afirst -eq 1 ] || printf ','
			afirst=0
			printf '{"name":%s,"path":%s,"exists":%s,"size":%s,"mtime":%s}' \
				"$(efx_json_str "$name")" \
				"$(efx_json_str "$path")" \
				"$([ -e "$path" ] && echo true || echo false)" \
				"$(efx_size "$path")" \
				"$(efx_mtime "$path")"
		done < <(artifacts_of "$c")
		printf ']'

		if [ "$c" = fsbl ]; then
			local limit used
			limit=$(fsbl_ram_limit)
			used=$(efx_size "$EFX_FSBL_DIR/bootloader.bin")
			printf ',"size_used":%s,"size_limit":%s' "$used" "$limit"
		fi

		printf '}'
	done
	printf ']}'
	echo
}

emit_text()
{
	local c state icon limit used

	printf '%-18s %-10s %s\n' 'COMPONENT' 'STATE' 'ARTIFACTS'
	printf '%-18s %-10s %s\n' '------------------' '----------' '---------'

	for c in "${COMPONENTS[@]}"; do
		[ -n "$ONLY" ] && [ "$ONLY" != "$c" ] && continue
		state=$(compute_state "$c")
		case "$state" in
		ok)        icon="${_C_GRN}ok${_C_OFF}" ;;
		stale)     icon="${_C_YEL}stale${_C_OFF}" ;;
		missing)   icon="missing" ;;
		failed)    icon="${_C_RED}failed${_C_OFF}" ;;
		cancelled) icon="${_C_YEL}cancelled${_C_OFF}" ;;
		*)         icon="$state" ;;
		esac

		local present=0 total=0 path name
		while IFS=$'\t' read -r name path; do
			[ -n "$path" ] || continue
			total=$((total + 1))
			[ -e "$path" ] && present=$((present + 1))
		done < <(artifacts_of "$c")

		printf '%-18s %-20b %s/%s present\n' "$(label_of "$c")" "$icon" "$present" "$total"
	done

	echo
	echo "board       : $BOARD ($SOC_VARIANT SoC, rv$ARCH)"
	echo "rootfs mode : $ROOTFS_MODE"
	echo "workspace   : $EFX_WORKSPACE_DIR"
	echo "free disk   : $(efx_free_gib "$EFX_REPO_DIR") GiB"

	if [ -z "$ONLY" ] || [ "$ONLY" = fsbl ]; then
		limit=$(fsbl_ram_limit)
		used=$(efx_size "$EFX_FSBL_DIR/bootloader.bin")
		if [ "$used" -gt 0 ] && [ "$limit" -gt 0 ]; then
			printf 'FSBL        : %s / %s bytes of on-chip RAM' "$used" "$limit"
			[ "$used" -gt "$limit" ] && printf ' %b' "${_C_RED}OVER BUDGET${_C_OFF}"
			echo
		fi
	fi

	if lock_busy; then
		echo "running     : $(cat "$EFX_STATE_DIR/lock-holder" 2>/dev/null)"
	fi
}

if [ $JSON -eq 1 ]; then
	emit_json
else
	emit_text
fi
