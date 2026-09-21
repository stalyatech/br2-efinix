#!/bin/bash
# efx config — wrap init.sh so that configuring is repeatable.
#
# init.sh is designed to be sourced once, interactively, into a pristine tree.
# It writes into tracked files, appends to them unguarded, needs a TTY and fails
# if the build directory already exists. This script makes it behave like a
# normal idempotent build step:
#
#   * the project's soc.h is copied, never modified
#   * the project-specific AXI map is injected from socmap/ instead of using
#     init.sh's -u/-e hard-coded (and for this design wrong) map
#   * every file init.sh touches is restored from git first, so running twice
#     produces byte-identical results
#   * the generated defconfig is post-processed to apply the overlays that
#     init.sh's own fragment handling drops on the floor

set -u

: "${EFX_DIR:?must be run through tools/efx/efx}"
. "$EFX_DIR/lib/common.sh"
. "$EFX_DIR/lib/conf.sh"
efx_conf_load || exit $EFX_EX_CONFIG

VERB=${1:-}
[ $# -gt 0 ] && shift

DRY_RUN=0
FORCE=0
WRITE=0

while [ $# -gt 0 ]; do
	case "$1" in
	--dry-run) DRY_RUN=1 ;;
	--force)   FORCE=1 ;;
	--write)   WRITE=1 ;;
	-h|--help)
		echo "Usage: efx config <detect|configure|reconfigure|regen-dt|reset|diff> [--dry-run] [--force] [--write]"
		exit 0
		;;
	*) efx_die $EFX_EX_USAGE "unknown option: $1" ;;
	esac
	shift
done

GEN_DEFCONFIG="$EFX_REPO_DIR/configs/efinix_${BOARD}_${ARCH}_defconfig"
STAGED_SOC_H="$EFX_STATE_DIR/soc.h"
DERIVED_UBOOT="$EFX_STATE_DIR/uboot_derived.cfg"
DERIVED_LINUX="$EFX_STATE_DIR/linux_derived.config"

# Files init.sh rewrites in place. Restoring these from git before a run is what
# makes the run idempotent — but only for the files that run will regenerate.
#
# init.sh does different amounts of work depending on the flag:
#
#   (none) / -a   full pass: check_soc_configuration rewrites linux.config and
#                 opensbi/soc.h, generate_device_tree rewrites the DTS files
#   -r            configuration only — it touches neither, because both
#                 check_soc_configuration and generate_device_tree sit behind the
#                 RECONFIGURE_ALL branch
#
# So restoring the device tree before a -r run would wipe a correct, generated
# tree and leave the committed one in its place, and the next kernel build would
# quietly compile the wrong hardware description.
#
# tracked_targets <scope>   scope = config | all
tracked_targets()
{
	# Always: add_packages() appends to the board defconfig and
	# prepare_buildroot_env() appends to the arch fragment, both unguarded.
	cat <<-EOF
	configs/efinix_${BOARD}_defconfig
	configs/riscv${ARCH}_fragment
	EOF

	[ "${1:-all}" = all ] || return 0

	cat <<-EOF
	boards/efinix/${BOARD}/linux/linux.config
	boards/efinix/${BOARD}/linux/linux.dts
	boards/efinix/${BOARD}/u-boot/uboot.dts
	boards/efinix/${BOARD}/opensbi/soc.h
	boards/efinix/common/dts/sapphire.dtsi
	EOF
}

# ------------------------------------------------------------------ detect ---

do_detect()
{
	efx_title "Autodetecting paths"
	efx_conf_detect

	printf '  %-20s %s\n' 'EFX_PROJECT_DIR'  "${EFX_PROJECT_DIR:-<not found>}"
	printf '  %-20s %s\n' 'EFINITY_HOME'     "${EFINITY_HOME:-<not found>}"
	printf '  %-20s %s\n' 'RISCV_BIN_DIR'    "${RISCV_BIN_DIR:-<not found>}"
	printf '  %-20s %s\n' 'SOC_VARIANT'      "$SOC_VARIANT"
	printf '  %-20s %s\n' 'soc.h'            "$EFX_SOC_H"

	if [ $WRITE -eq 1 ]; then
		efx_conf_write
		efx_info "wrote $EFX_DIR/efx.conf"
	else
		efx_info "re-run with --write to save these into efx.conf"
	fi
}

# ------------------------------------------------------------- staging soc.h ---

# Copy the project's soc.h and append the project-specific AXI map before the
# final #endif. The original is left untouched.
#
# CRLF is stripped on the way through. The Efinity project is authored on
# Windows, and init.sh compares extracted values with [[ $ext_c == 1 ]] — against
# a CR-terminated "1" that never matches, which would quietly drop the compressed
# instruction extension from the kernel config. Normalising here fixes that for
# init.sh, for the device tree generator and for the OpenSBI build in one place.
stage_soc_h()
{
	[ -f "$EFX_SOC_H" ] || efx_die $EFX_EX_CONFIG "soc.h not found: $EFX_SOC_H"

	if [ -n "$SOCMAP_OVERLAY" ]; then
		local overlay="$EFX_DIR/$SOCMAP_OVERLAY"
		[ -f "$overlay" ] || efx_die $EFX_EX_CONFIG "SOCMAP_OVERLAY not found: $overlay"

		# Drop the last #endif, append the overlay, put #endif back.
		awk '
			{ sub(/\r$/, "") }
			/^[[:space:]]*#endif/ { last = NR }
			{ lines[NR] = $0 }
			END {
				for (i = 1; i <= NR; i++)
					if (i != last) print lines[i]
			}
		' "$EFX_SOC_H" > "$STAGED_SOC_H"

		{
			printf '\n/* ---- injected by efx from %s ---- */\n' "$SOCMAP_OVERLAY"
			sed 's/\r$//' "$overlay"
			printf '\n#endif /* SOC_H */\n'
		} >> "$STAGED_SOC_H"

		efx_info "staged soc.h + $SOCMAP_OVERLAY -> $STAGED_SOC_H"
	else
		sed 's/\r$//' "$EFX_SOC_H" > "$STAGED_SOC_H"
		efx_info "staged soc.h (no overlay) -> $STAGED_SOC_H"
	fi

	grep -q $'\r' "$STAGED_SOC_H" && efx_warn "staged soc.h still contains CR characters"
	return 0
}

soc_define() { efx_soc_define "$STAGED_SOC_H" "$1"; }

# Emit the config fragments whose values come straight from soc.h, so they can
# never drift from the hardware description.
generate_derived_fragments()
{
	local uart_base clint_hz

	uart_base=$(soc_define SYSTEM_UART_0_IO_CTRL)
	clint_hz=$(soc_define SYSTEM_CLINT_HZ)

	[ -n "$uart_base" ] || efx_die $EFX_EX_CONFIG "SYSTEM_UART_0_IO_CTRL missing from $STAGED_SOC_H"

	cat > "$DERIVED_UBOOT" <<-EOF
	# Generated by efx from $EFX_SOC_H — do not edit.
	# boards/efinix/common/u-boot/uboot_${ARCH}_defconfig hard-codes the soft-SoC
	# UART at 0xF8010000; on this design UART0 is somewhere else entirely.
	CONFIG_DEBUG_UART_BASE=${uart_base^^}
	CONFIG_DEBUG_UART_CLOCK=${clint_hz:-200000000}
	EOF

	{
		echo "# Generated by efx from $EFX_SOC_H — do not edit."

		if [ "$ROOTFS_MODE" = initramfs ]; then
			# The device tree generator always writes bootargs that mount an SD
			# card ("root=/dev/mmcblk0p2 rootwait"). With the rootfs built into
			# the kernel there is no such device — and on this design the hard
			# SoC cannot reach the SD host at all yet — so override the command
			# line instead of waiting forever for a disk that will never appear.
			echo 'CONFIG_CMDLINE="console=ttySL0 earlycon"'
			echo 'CONFIG_CMDLINE_FORCE=y'
		elif [ "$ROOTFS_MODE" = spinor ]; then
			# The root filesystem is a squashfs on the second SPI flash. Its
			# mtdblock number follows the order the partitions are declared in
			# (ROOTFS_MTDBLOCK); the kernel has no way to ask for one by name.
			echo "CONFIG_CMDLINE=\"console=ttySL0 earlycon root=/dev/mtdblock${ROOTFS_MTDBLOCK} rootfstype=squashfs ro rootwait\""
			echo 'CONFIG_CMDLINE_FORCE=y'
		fi
	} > "$DERIVED_LINUX"

	efx_info "derived U-Boot UART base ${uart_base} @ ${clint_hz:-200000000} Hz"
	[ "$ROOTFS_MODE" = initramfs ] && efx_info "derived kernel cmdline override (initramfs: no root= device)"
	return 0
}

# ------------------------------------------------- dt generator overrides ---

# The device tree generator's generic JSON describes what a peripheral node
# looks like but not which device instance it is. Efinix supply that binding only
# from their -u/-e override directories, which do not fit this design.
#
# With no -u/-e, init.sh resolves the board override directory to
# config/<type>/<arch>/<board>, so dropping our files there gets them picked up
# with no flags at all. The generator is cloned at runtime and untracked, which is
# why the files live in the repo under dtoverlay/ and are installed on every run.
install_dt_overrides()
{
	local dt_dir="$EFX_REPO_DIR/boards/efinix/common/sapphire-soc-dt-generator"
	local type dest count=0

	[ -d "$dt_dir" ] || return 0

	for type in linux uboot; do
		[ -d "$EFX_DIR/dtoverlay/$type" ] || continue
		dest="$dt_dir/config/$type/$ARCH/$BOARD"
		mkdir -p "$dest"
		for f in "$EFX_DIR/dtoverlay/$type"/*.json; do
			[ -f "$f" ] || continue
			cp -f "$f" "$dest/"
			count=$((count + 1))
		done
	done

	[ $count -gt 0 ] && efx_info "installed $count device tree override(s) into the generator"
	return 0
}

# --------------------------------------------------------------- tree guard ---

backup_tree()
{
	local scope=${1:-all}
	local dest="$EFX_STATE_DIR/tree-backup-$(date +%Y%m%d-%H%M%S)" f
	mkdir -p "$dest"
	while read -r f; do
		[ -f "$EFX_REPO_DIR/$f" ] || continue
		mkdir -p "$dest/$(dirname "$f")"
		cp -f "$EFX_REPO_DIR/$f" "$dest/$f"
	done < <(tracked_targets "$scope")
	efx_info "backed up generated files to $dest"

	# Keep the five most recent backups; older ones are noise.
	ls -1dt "$EFX_STATE_DIR"/tree-backup-* 2>/dev/null | tail -n +6 | xargs -r rm -rf
}

restore_tree()
{
	local scope=${1:-all}
	local f restored=0

	while read -r f; do
		if git -C "$EFX_REPO_DIR" ls-files --error-unmatch "$f" >/dev/null 2>&1; then
			if ! git -C "$EFX_REPO_DIR" diff --quiet -- "$f" 2>/dev/null; then
				git -C "$EFX_REPO_DIR" checkout -- "$f"
				restored=$((restored + 1))
			fi
		fi
	done < <(tracked_targets "$scope")

	# The merged defconfig is generated, not tracked: remove it outright.
	rm -f "$GEN_DEFCONFIG"
	# merge_config.sh leaves a stray .config in the repo root if it dies.
	rm -f "$EFX_REPO_DIR/.config" "$EFX_REPO_DIR/.config.old"

	efx_info "restored $restored tracked file(s) to their committed state ($scope scope)"
}

# ---------------------------------------------------------------- init.sh ---

# Build the argv in one fixed order every time: init.sh's getopts is
# order-sensitive (-s appends to EXTRA_HW_FEATURES, -x overwrites it), so a
# stable order is the difference between reproducible and not.
init_argv()
{
	local -a argv=("$BOARD" "$STAGED_SOC_H" -m "$ARCH" -d "$WORKSPACE")

	[ -n "$DT_FEATURES" ] && argv+=(-s "$DT_FEATURES")

	# -k 2 (kernel 5.10) is rejected: init.sh:859 reads
	#   [ "$KERNEL_SELECTION" ! = "2" ]
	# with a space after '!', which makes the test error out. Kernel 6.6 only.
	argv+=(-k 1)

	printf '%s\n' "${argv[@]}"
}

run_init()
{
	local -a argv
	local extra=$1 cmd

	mapfile -t argv < <(init_argv)
	[ -n "$extra" ] && argv+=("$extra")

	# Quote for the string that `script` will hand to bash.
	cmd="source ./init.sh"
	local a
	for a in "${argv[@]}"; do
		cmd+=" $(printf '%q' "$a")"
	done

	if [ $DRY_RUN -eq 1 ]; then
		efx_title "Dry run"
		echo "cd $EFX_REPO_DIR"
		echo "$cmd"
		return 0
	fi

	# init.sh calls `tput cols`, so it needs a terminal. `script` supplies one
	# even when we are running under the web GUI with pipes for stdio.
	efx_run_step config "${VERB}" -- \
		env -C "$EFX_REPO_DIR" script -qec "$cmd" /dev/null
}

# ------------------------------------------------- generated defconfig fixups ---

# init.sh drops three things we need. Patch the merged defconfig and re-run the
# Buildroot defconfig target so the fixes actually reach $BUILD_DIR/.config.
postprocess_defconfig()
{
	local ub_extra lx_extra

	[ -f "$GEN_DEFCONFIG" ] || efx_die $EFX_EX_CONFIG "expected $GEN_DEFCONFIG to exist after init.sh"

	efx_title "Applying efx overlays to $(basename "$GEN_DEFCONFIG")"

	ub_extra="$EFX_DIR/overlays/uboot_ti375_oob.cfg $DERIVED_UBOOT"
	lx_extra="$EFX_DIR/overlays/linux_ti375_oob.config $DERIVED_LINUX"

	# U-Boot fragments. init.sh:567 tests a literal "$(BR2_EXTERNAL_EFINIX_PATH)/..."
	# string with -f, which is never a real path, so the board fragment silently
	# never gets added. Append ours (and the board's) here where it takes effect.
	python3 - "$GEN_DEFCONFIG" "$ub_extra" "$lx_extra" <<-'PY'
		import sys, re

		path, ub_extra, lx_extra = sys.argv[1], sys.argv[2], sys.argv[3]
		text = open(path).read()

		def append_to(key, extra):
		    global text
		    pat = re.compile(r'^(%s=")(.*)(")$' % re.escape(key), re.M)
		    m = pat.search(text)
		    if m:
		        current = m.group(2)
		        parts = current.split()
		        for item in extra.split():
		            if item not in parts:
		                parts.append(item)
		        text = text[:m.start()] + '%s%s%s' % (m.group(1), ' '.join(parts), m.group(3)) + text[m.end():]
		    else:
		        text += '\n%s="%s"\n' % (key, extra)

		append_to('BR2_TARGET_UBOOT_CONFIG_FRAGMENT_FILES', ub_extra)
		append_to('BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES', lx_extra)

		open(path, 'w').write(text)
	PY

	efx_info "u-boot fragments  += overlays/uboot_ti375_oob.cfg, state/uboot_derived.cfg"
	efx_info "kernel fragments  += overlays/linux_ti375_oob.config, state/linux_derived.config"

	# Rootfs mode. With no SD host reachable from the hard SoC yet, the rootfs has
	# to travel inside the kernel image — there is nothing to load it from.
	sed -i '/^BR2_TARGET_ROOTFS_INITRAMFS=/d; /^BR2_TARGET_ROOTFS_SQUASHFS/d; /^BR2_TARGET_GENERIC_REMOUNT_ROOTFS_RW=/d' "$GEN_DEFCONFIG"
	case "$ROOTFS_MODE" in
	initramfs)
		echo 'BR2_TARGET_ROOTFS_INITRAMFS=y' >> "$GEN_DEFCONFIG"
		efx_info "rootfs mode       = initramfs (embedded in the kernel image)"
		;;
	spinor)
		# A squashfs written to the second SPI flash from a running system.
		# The kernel image then carries nothing but the kernel, which is what
		# keeps it inside its 8 MiB slot as drivers are added.
		printf '%s\n' 'BR2_TARGET_ROOTFS_SQUASHFS=y' \
			'BR2_TARGET_ROOTFS_SQUASHFS4_GZIP=y' \
			'# BR2_TARGET_GENERIC_REMOUNT_ROOTFS_RW is not set' >> "$GEN_DEFCONFIG"
		efx_info "rootfs mode       = spinor (squashfs on mtdblock$ROOTFS_MTDBLOCK, read only)"
		;;
	*)
		efx_info "rootfs mode       = sdcard (genimage sdcard.img)"
		;;
	esac

	# Devices the generator cannot describe (reserved memory, NPU and FCU
	# nodes): the dtsi that the generated linux.dts includes has to be copied
	# into the kernel tree with it.
	python3 - "$GEN_DEFCONFIG" "$EFX_DIR/dts/ti375_oob-linux.dtsi" <<-'PY'
		import re, sys
		path, dtsi = sys.argv[1], sys.argv[2]
		t = open(path).read()
		key = 'BR2_LINUX_KERNEL_CUSTOM_DTS_PATH'
		m = re.search(r'^%s="(.*)"$' % key, t, re.M)
		items = m.group(1).split() if m else []
		if dtsi not in items:
		    items.append(dtsi)
		line = '%s="%s"' % (key, ' '.join(items))
		t = t[:m.start()] + line + t[m.end():] if m else t + '\n' + line + '\n'
		open(path, 'w').write(t)
	PY
	efx_info "kernel dts        += dts/ti375_oob-linux.dtsi"

	# Project software, built from the Efinity project's own sources.
	sed -i '/^BR2_PACKAGE_STALYA_/d; /^BR2_PACKAGE_PX4_FCU/d' "$GEN_DEFCONFIG"
	local sw
	for sw in $PROJECT_SW; do
		case "$sw" in
		npu)
			[ -d "$EFX_PROJECT_DIR/ip/stalyanpu/sw/linux" ] \
				|| efx_die $EFX_EX_CONFIG "PROJECT_SW=npu: no ip/stalyanpu/sw/linux in $EFX_PROJECT_DIR"
			printf '%s\n' 'BR2_PACKAGE_STALYA_NPU=y' \
				"BR2_PACKAGE_STALYA_NPU_SRCDIR=\"$EFX_PROJECT_DIR/ip/stalyanpu/sw\"" >> "$GEN_DEFCONFIG"
			;;
		fcu)
			[ -d "$EFX_PROJECT_DIR/sw/linux/fcu_rproc" ] \
				|| efx_die $EFX_EX_CONFIG "PROJECT_SW=fcu: no sw/linux/fcu_rproc in $EFX_PROJECT_DIR"
			printf '%s\n' 'BR2_PACKAGE_STALYA_FCU=y' \
				"BR2_PACKAGE_STALYA_FCU_PROJECT=\"$EFX_PROJECT_DIR\"" \
				"BR2_PACKAGE_STALYA_FCU_BAREMETAL_BIN=\"$RISCV_BIN_DIR\"" \
				"BR2_PACKAGE_STALYA_FCU_BAREMETAL_PREFIX=\"$RISCV_PREFIX\"" >> "$GEN_DEFCONFIG"
			;;
		px4)
			[ -n "$PX4_ELF" ] \
				|| efx_die $EFX_EX_CONFIG "PROJECT_SW=px4: PX4_ELF is empty"
			[ -f "$PX4_ELF" ] \
				|| efx_die $EFX_EX_CONFIG "PROJECT_SW=px4: no such file: $PX4_ELF"
			printf '%s\n' 'BR2_PACKAGE_PX4_FCU=y' \
				"BR2_PACKAGE_PX4_FCU_ELF=\"$PX4_ELF\"" >> "$GEN_DEFCONFIG"
			;;
		*)
			efx_die $EFX_EX_CONFIG "PROJECT_SW: unknown item '$sw' (npu, fcu, px4)"
			;;
		esac
	done
	efx_info "project software  = ${PROJECT_SW:-none}"

	# Network. Buildroot's skeleton leaves eth0 alone; the overlay below
	# gives it the address the board is reached at, or nothing at all.
	sed -i '/^BR2_ROOTFS_OVERLAY=/d' "$GEN_DEFCONFIG"
	local overlay_dir="$EFX_DIR/state/rootfs_overlay"
	rm -rf "$overlay_dir"
	if [ -n "$NET_ADDRESS" ]; then
		local addr=${NET_ADDRESS%%/*} prefix=${NET_ADDRESS##*/}
		[ "$prefix" = "$NET_ADDRESS" ] && prefix=24
		mkdir -p "$overlay_dir/etc/network"
		{
			printf '# Generated by efx config from NET_ADDRESS=%s\n\n' "$NET_ADDRESS"
			printf 'auto lo\niface lo inet loopback\n\n'
			printf 'auto eth0\niface eth0 inet static\n'
			printf '\taddress %s\n' "$addr"
			printf '\tnetmask %s\n' "$(efx_netmask "$prefix")"
		} > "$overlay_dir/etc/network/interfaces"
		efx_info "network           = eth0 $NET_ADDRESS (rootfs overlay)"
	else
		efx_info "network           = eth0 left down"
	fi

	# A read-only root is what Buildroot's skeleton already expects: /var's
	# cache, log, run and spool are symlinks into tmpfs, and only /var/lib is
	# in the image. What is missing is somewhere for state that has to last a
	# reboot, so the flash's data partition is mounted at /data.
	#
	# Nothing is formatted here: erasing a partition takes minutes and would
	# hold up every boot. "efx-format-store" does that once, by hand.
	if [ "$ROOTFS_MODE" = spinor ]; then
		mkdir -p "$overlay_dir/data" "$overlay_dir/mnt/fcufw" "$overlay_dir/etc/init.d" \
			"$overlay_dir/usr/sbin"

		cat > "$overlay_dir/etc/init.d/S00data" <<-'SH'
			#!/bin/sh
			# Mount what the board keeps across reboots. The store is formatted
			# once with efx-format-store; an unformatted partition is left alone.
			[ "$1" = start ] || exit 0

			for label in data fcu_firmware; do
				for d in /sys/class/mtd/mtd[0-9]*; do
					[ -f "$d/name" ] || continue
					[ "$(cat "$d/name")" = "$label" ] || continue
					n=$(basename "$d"); n=${n#mtd}
					case "$label" in
					data)         mount -t jffs2 "/dev/mtdblock$n" /data 2>/dev/null ;;
					fcu_firmware) mount -t jffs2 "/dev/mtdblock$n" /mnt/fcufw 2>/dev/null ;;
					esac
				done
			done
		SH
		chmod +x "$overlay_dir/etc/init.d/S00data"

		cat > "$overlay_dir/usr/sbin/efx-format-store" <<-'SH'
			#!/bin/sh
			# Erase and make a jffs2 of the flash partitions the board writes to.
			# Minutes per partition, so this is a deliberate step, not a boot one.
			usage() { echo "usage: $0 data|fcu_firmware|all"; exit 1; }

			format() {
				for d in /sys/class/mtd/mtd[0-9]*; do
					[ -f "$d/name" ] || continue
					[ "$(cat "$d/name")" = "$1" ] || continue
					n=$(basename "$d"); n=${n#mtd}
					case "$1" in
					data)         mnt=/data ;;
					fcu_firmware) mnt=/mnt/fcufw ;;
					esac
					umount "$mnt" 2>/dev/null
					echo "erasing $1 (/dev/mtd$n), this takes a while"
					flash_erase -j "/dev/mtd$n" 0 0 || return 1
					mount -t jffs2 "/dev/mtdblock$n" "$mnt" && echo "$1 -> $mnt"
					return 0
				done
				echo "no partition labelled $1"
				return 1
			}

			case "${1:-}" in
			data|fcu_firmware) format "$1" ;;
			all)               format data; format fcu_firmware ;;
			*)                 usage ;;
			esac
		SH
		chmod +x "$overlay_dir/usr/sbin/efx-format-store"
		efx_info "read only root    = /data and /mnt/fcufw from the flash (format by hand)"
	fi

	if [ -d "$overlay_dir" ]; then
		printf '%s\n' "BR2_ROOTFS_OVERLAY=\"$overlay_dir\"" >> "$GEN_DEFCONFIG"
	fi

	# Rootfs size. init.sh always appends configs/extra_packages_fragment
	# (perl, python, vim, benchmarks: ~100 MB). A rootfs that has to fit in
	# the kernel image and come out of SPI flash wants busybox only.
	if [ "$ROOTFS_PACKAGES" = minimal ]; then
		local pkgs
		pkgs=$(grep -oE '^BR2_PACKAGE_[A-Z0-9_]+' "$EFX_REPO_DIR/configs/extra_packages_fragment" | sort -u)
		for p in $pkgs; do
			# Keep packages that base_defconfig asks for on its own.
			grep -q "^${p}=" "$EFX_REPO_DIR/configs/base_defconfig" && continue
			sed -i "/^${p}=/d" "$GEN_DEFCONFIG"
		done
		efx_info "rootfs packages   = minimal (extra_packages_fragment dropped)"
	fi

	# The FCU firmware store lives on the second SPI flash, so the image
	# needs the tools that erase and write an MTD.
	sed -i '/^BR2_PACKAGE_MTD/d' "$GEN_DEFCONFIG"
	printf '%s\n' 'BR2_PACKAGE_MTD=y' \
		'BR2_PACKAGE_MTD_FLASH_ERASE=y' \
		'BR2_PACKAGE_MTD_FLASHCP=y' \
		'BR2_PACKAGE_MTD_LSMTD=y' >> "$GEN_DEFCONFIG"


	# The initramfs Image has to be cut from the vmlinux Buildroot relinks
	# after the rootfs, which only a post-image hook sees. The stock hook,
	# post_create_fs.sh, builds sdcard.img with genimage; with the rootfs in the
	# kernel there is no SD card to make, and it needs mtools, so it goes.
	if [ "$ROOTFS_MODE" = spinor ]; then
		# Nothing to assemble: the kernel is plain and the squashfs is written
		# to the flash from the board. The stock hook only makes an SD image.
		python3 - "$GEN_DEFCONFIG" <<-'PY'
			import re, sys
			path = sys.argv[1]
			t = open(path).read()
			m = re.search(r'^BR2_ROOTFS_POST_IMAGE_SCRIPT="(.*)"$', t, re.M)
			if m:
			    items = [i for i in m.group(1).split()
			             if not i.endswith('/post_create_fs.sh')]
			    line = 'BR2_ROOTFS_POST_IMAGE_SCRIPT="%s"' % ' '.join(items)
			    t = t[:m.start()] + line + t[m.end():]
			    open(path, 'w').write(t)
		PY
		efx_info "post-image hook  = none (plain kernel, squashfs written from the board)"
	fi

	if [ "$ROOTFS_MODE" = initramfs ]; then
		python3 - "$GEN_DEFCONFIG" "$EFX_DIR/scripts/post_image_initramfs.sh" <<-'PY'
			import re, sys
			path, hook = sys.argv[1], sys.argv[2]
			t = open(path).read()
			m = re.search(r'^BR2_ROOTFS_POST_IMAGE_SCRIPT="(.*)"$', t, re.M)
			items = m.group(1).split() if m else []
			items = [i for i in items if not i.endswith('/post_create_fs.sh')]
			if hook not in items:
			    items.append(hook)
			line = 'BR2_ROOTFS_POST_IMAGE_SCRIPT="%s"' % ' '.join(items)
			t = t[:m.start()] + line + t[m.end():] if m else t + '\n' + line + '\n'
			open(path, 'w').write(t)
		PY
		efx_info "post-image hook  = post_image_initramfs.sh (Image from the final vmlinux; no sdcard.img)"
	fi

	# Optional cache relocation, so a 30+ GiB build does not land in $HOME.
	if [ -n "$EFX_DL_DIR" ]; then
		sed -i '/^BR2_DL_DIR=/d' "$GEN_DEFCONFIG"
		echo "BR2_DL_DIR=\"$EFX_DL_DIR\"" >> "$GEN_DEFCONFIG"
	fi
	if [ -n "$EFX_CCACHE_DIR" ]; then
		sed -i '/^BR2_CCACHE_DIR=/d' "$GEN_DEFCONFIG"
		echo "BR2_CCACHE_DIR=\"$EFX_CCACHE_DIR\"" >> "$GEN_DEFCONFIG"
	fi

	efx_title "Re-applying defconfig"
	efx_run_step config defconfig -- \
		make -C "$EFX_BUILDROOT_DIR" O="$EFX_BUILD_DIR" \
			BR2_EXTERNAL="$EFX_REPO_DIR" "efinix_${BOARD}_${ARCH}_defconfig"
}

# ------------------------------------------------------------------- verbs ---

# The generator cannot express the reserved memory and the NPU and FCU nodes;
# they live in dts/ti375_oob-linux.dtsi. It is included at the very end of the
# generated linux.dts, after sapphire.dtsi and the root node: dtc wants every
# /dts-v1/ before the first node, and there the dtsi merges last.
append_board_dtsi()
{
	local dts="$EFX_REPO_DIR/boards/efinix/$BOARD/linux/linux.dts"
	local inc='/include/ "ti375_oob-linux.dtsi"'

	[ -f "$dts" ] || return 0
	grep -qxF "$inc" "$dts" && return 0
	printf '\n%s\n' "$inc" >> "$dts"
	efx_info "linux.dts         += $inc"
}

do_configure()
{
	efx_conf_validate || efx_die $EFX_EX_CONFIG "fix efx.conf first (see messages above)"

	if [ -d "$EFX_BUILD_DIR" ] && [ $FORCE -eq 0 ]; then
		efx_die $EFX_EX_CONFIG \
			"$EFX_BUILD_DIR already exists. Use 'efx config reconfigure' (or 'regen-dt' to also rebuild the device tree), or pass --force to start over."
	fi

	[ $DRY_RUN -eq 0 ] && efx_lock_acquire "config configure"
	trap 'efx_lock_release' EXIT

	stage_soc_h
	generate_derived_fragments
	install_dt_overrides

	if [ $DRY_RUN -eq 0 ]; then
		backup_tree
		restore_tree
		if [ $FORCE -eq 1 ] && [ -d "$EFX_BUILD_DIR" ]; then
			# This is the toolchain as well as the artifacts: the next build of
			# anything is a from-scratch build. `reconfigure` is almost always
			# what you actually want.
			efx_warn "--force: removing $EFX_BUILD_DIR ($(du -sh "$EFX_BUILD_DIR" 2>/dev/null | cut -f1))"
			efx_warn "this discards the cross toolchain and every built package"
			rm -rf "$EFX_BUILD_DIR"
		fi
	fi

	run_init '' || return $?
	[ $DRY_RUN -eq 1 ] && return 0

	append_board_dtsi
	postprocess_defconfig
	efx_info "configured: $EFX_BUILD_DIR/.config"
}

do_reconfigure()
{
	local flag=$1   # -r or -a

	efx_conf_validate || efx_die $EFX_EX_CONFIG "fix efx.conf first"
	[ -d "$EFX_BUILD_DIR" ] || efx_die $EFX_EX_CONFIG \
		"$EFX_BUILD_DIR does not exist — run 'efx config configure' first"

	[ $DRY_RUN -eq 0 ] && efx_lock_acquire "config $VERB"
	trap 'efx_lock_release' EXIT

	stage_soc_h
	generate_derived_fragments
	install_dt_overrides

	# -r regenerates neither the device tree nor linux.config, so restoring them
	# would replace generated files with stale committed ones.
	local scope=all
	[ "$flag" = -r ] && scope=config

	if [ $DRY_RUN -eq 0 ]; then
		backup_tree "$scope"
		restore_tree "$scope"
	fi

	run_init "$flag" || return $?
	[ $DRY_RUN -eq 1 ] && return 0

	append_board_dtsi
	postprocess_defconfig
	efx_info "reconfigured: $EFX_BUILD_DIR/.config"
}

do_reset()
{
	efx_title "Restoring the repo working tree"
	backup_tree
	restore_tree
	efx_info "done — run 'efx config configure' to regenerate"
}

do_diff()
{
	efx_title "Working tree changes made by the configuration step"
	local f any=0
	while read -r f; do
		git -C "$EFX_REPO_DIR" ls-files --error-unmatch "$f" >/dev/null 2>&1 || continue
		if ! git -C "$EFX_REPO_DIR" diff --quiet -- "$f" 2>/dev/null; then
			any=1
			git -C "$EFX_REPO_DIR" --no-pager diff --stat -- "$f"
		fi
	done < <(tracked_targets all)

	[ -f "$GEN_DEFCONFIG" ] && { any=1; echo "generated: ${GEN_DEFCONFIG#"$EFX_REPO_DIR"/}"; }
	[ $any -eq 0 ] && efx_info "working tree is clean"
}

case "$VERB" in
detect)      do_detect ;;
configure)   do_configure ;;
reconfigure) do_reconfigure -r ;;
regen-dt)    do_reconfigure -a ;;
reset)       do_reset ;;
diff)        do_diff ;;
''|-h|--help)
	echo "Usage: efx config <detect|configure|reconfigure|regen-dt|reset|diff> [--dry-run] [--force] [--write]"
	exit 0
	;;
*)
	efx_die $EFX_EX_USAGE "unknown verb: $VERB"
	;;
esac
