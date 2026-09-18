#!/bin/bash
# efx fsbl — build the first-stage bootloader from the Efinity project BSP.
#
# The FSBL is not a Buildroot package: it is the SaxonSoc bootloader that ships
# inside the Efinity project, rebuilt against br2-efinix's bootloaderConfig.h so
# that it loads OpenSBI and U-Boot from SPI flash instead of a bare-metal app.
#
# boards/efinix/common/modify_bootloader.sh does this too, but it insists on an
# Efinity RISC-V IDE toolchain directory. On this machine that IDE exists only as
# Windows .exe binaries, so we drive the same BSP makefiles with a native Linux
# toolchain and derive -march/-mabi from soc.h instead of trusting the BSP's
# hard-coded defaults.
#
# The output must fit in the SoC's on-chip RAM (SYSTEM_RAM_A_SIZE, 16 KiB here).
# Overflowing it produces a bootloader that silently does not boot, so the size
# check is a hard gate, not a warning.

set -u

: "${EFX_DIR:?must be run through tools/efx/efx}"
. "$EFX_DIR/lib/common.sh"
. "$EFX_DIR/lib/conf.sh"
efx_conf_load || exit $EFX_EX_CONFIG

VERB=${1:-build}
[ $# -gt 0 ] && shift

FORCE=0
IDE_DIR=''
while [ $# -gt 0 ]; do
	case "$1" in
	--force) FORCE=1 ;;
	--ide)   IDE_DIR=${2:-}; shift ;;
	--ide=*) IDE_DIR=${1#*=} ;;
	-h|--help)
		echo "Usage: efx fsbl <build|rebuild|clean|restore|status> [--force] [--ide <dir>]"
		exit 0
		;;
	*) efx_die $EFX_EX_USAGE "unknown option: $1" ;;
	esac
	shift
done

BSP_ROOT="$EFX_PROJECT_DIR/embedded_sw/$EFX_FSBL_BSP_NAME"
BOOTLOADER_DIR="$BSP_ROOT/software/standalone/bootloader"
SAPPHIRE_DIR="$BSP_ROOT/bsp/efinix/EfxSapphireSoc"
SOC_MK="$SAPPHIRE_DIR/include/soc.mk"
BSP_SOC_H="$SAPPHIRE_DIR/include/soc.h"
OUT_DIR="$EFX_FSBL_DIR"
BACKUP_DIR="$EFX_STATE_DIR/fsbl-backup"

soc_define() { efx_soc_define "$BSP_SOC_H" "$1"; }

check_layout()
{
	[ -d "$BSP_ROOT" ]       || efx_die $EFX_EX_CONFIG "BSP not found: $BSP_ROOT (check FSBL_HOST / EFX_PROJECT_DIR)"
	[ -d "$BOOTLOADER_DIR" ] || efx_die $EFX_EX_CONFIG "bootloader sources not found: $BOOTLOADER_DIR"
	[ -f "$SOC_MK" ]         || efx_die $EFX_EX_CONFIG "soc.mk not found: $SOC_MK"
	[ -f "$BSP_SOC_H" ]      || efx_die $EFX_EX_CONFIG "soc.h not found: $BSP_SOC_H"
}

# Build -march/-mabi from what soc.h says the hardware actually implements.
#
# The BSP's riscv64-unknown-elf.mk computes these itself, but it targets the
# vendor's GCC 8.3. Modern GCC splits Zicsr and Zifencei out of the base ISA:
# GCC 15 expands rv32imafdc to rv32imafdc_zicsr_... (so csrr assembles) but
# NOT zifencei, and the BSP uses fence.i. Spelling both out keeps this working
# on old and new toolchains alike.
derive_isa()
{
	local march=rv32i mabi=ilp32

	[ "$(soc_define SYSTEM_RISCV_ISA_EXT_M)" = 1 ] && march+=m
	[ "$(soc_define SYSTEM_RISCV_ISA_EXT_A)" = 1 ] && march+=a
	[ "$(soc_define SYSTEM_RISCV_ISA_EXT_F)" = 1 ] && { march+=f; mabi=ilp32f; }
	[ "$(soc_define SYSTEM_RISCV_ISA_EXT_D)" = 1 ] && { march+=d; mabi=ilp32d; }
	[ "$(soc_define SYSTEM_RISCV_ISA_EXT_C)" = 1 ] && march+=c

	march+=_zicsr_zifencei

	FSBL_MARCH=$march
	FSBL_MABI=$mabi
}

cpu_count()
{
	local i n=1
	for i in 3 2 1 0; do
		if grep -q "SYSTEM_PLIC_SYSTEM_CORES_${i}_EXTERNAL_INTERRUPT" "$BSP_SOC_H"; then
			n=$((i + 1))
			break
		fi
	done
	echo "$n"
}

toolchain_setup()
{
	if [ -n "$IDE_DIR" ]; then
		local gcc
		gcc=$(find "$IDE_DIR/toolchain/bin" -maxdepth 1 -name '*-gcc' 2>/dev/null | head -1)
		[ -n "$gcc" ] || efx_die $EFX_EX_CONFIG "no *-gcc under $IDE_DIR/toolchain/bin"
		FSBL_BIN_DIR=$(dirname "$gcc")
		FSBL_PREFIX=$(basename "$gcc"); FSBL_PREFIX=${FSBL_PREFIX%gcc}
		efx_info "using vendor toolchain: $gcc"
	else
		FSBL_BIN_DIR=$RISCV_BIN_DIR
		FSBL_PREFIX=$RISCV_PREFIX
	fi

	[ -x "$FSBL_BIN_DIR/${FSBL_PREFIX}gcc" ] \
		|| efx_die $EFX_EX_CONFIG "toolchain not executable: $FSBL_BIN_DIR/${FSBL_PREFIX}gcc"
}

# The project's own bootloaderConfig.h boots a bare-metal/NuttX application.
# Keep it so `efx fsbl restore` can put the project back the way it was.
backup_originals()
{
	mkdir -p "$BACKUP_DIR"
	[ -f "$BACKUP_DIR/bootloaderConfig.h" ] || cp -f "$BOOTLOADER_DIR/src/bootloaderConfig.h" "$BACKUP_DIR/"
	[ -f "$BACKUP_DIR/soc.mk" ]             || cp -f "$SOC_MK" "$BACKUP_DIR/"
}

# The project-specific configuration (tools/efx/fsbl) also starts the FCU
# through amp_ctrl; the stock one only loads OpenSBI and U-Boot.
install_linux_config()
{
	local src
	src=$(efx_fsbl_config)
	[ -f "$src" ] || efx_die $EFX_EX_CONFIG "missing $src (FSBL_CONFIG)"

	cp -f "$src" "$BOOTLOADER_DIR/src/bootloaderConfig.h"
	efx_info "installed ${src#"$EFX_REPO_DIR"/} as bootloaderConfig.h"

	local cores smp
	cores=$(cpu_count)
	if [ "$cores" -gt 1 ]; then smp=1; else smp=0; fi

	# SMP has to match the hardware: the bootloader releases the secondary harts
	# only when built with -DSMP, and doing that on a single-core SoC hangs.
	sed -i -E \
		-e 's|^[[:space:]]*#?[[:space:]]*CFLAGS\+=-DSMP.*$|#CFLAGS+=-DSMP|' \
		-e 's|^DEBUG[[:space:]]*\?=.*$|DEBUG?=no|' \
		-e 's|^DEBUG_OG[[:space:]]*\?=.*$|DEBUG_OG?=no|' \
		"$SOC_MK"

	grep -q '^DEBUG?=' "$SOC_MK"    || echo 'DEBUG?=no'    >> "$SOC_MK"
	grep -q '^DEBUG_OG?=' "$SOC_MK" || echo 'DEBUG_OG?=no' >> "$SOC_MK"

	if [ "$smp" = 1 ]; then
		sed -i 's|^#CFLAGS+=-DSMP|CFLAGS+=-DSMP|' "$SOC_MK"
		grep -q '^CFLAGS+=-DSMP' "$SOC_MK" || echo 'CFLAGS+=-DSMP' >> "$SOC_MK"
	fi
	efx_info "SoC has $cores core(s) — SMP $([ "$smp" = 1 ] && echo enabled || echo disabled)"
}

# sw/amp/amp_ctrl.h lives next to the RTL in the Efinity project, so the
# register map has exactly one definition.
fsbl_cflags()
{
	local f="${EFX_FSBL_CFLAGS_EXTRA:-}"
	[ -d "$EFX_PROJECT_DIR/sw/amp" ] && f="-I$EFX_PROJECT_DIR/sw/amp $f"
	echo "$f"
}

do_make()
{
	local target=$1

	efx_run_step fsbl "$target" -- \
		env -C "$BOOTLOADER_DIR" \
			PATH="$FSBL_BIN_DIR:$PATH" \
			make "$target" \
				BSP_PATH="$SAPPHIRE_DIR" \
				RISCV_BIN="$FSBL_PREFIX" \
				MARCH="$FSBL_MARCH" \
				MABI="$FSBL_MABI" \
				CFLAGS_ARGS="$(fsbl_cflags)"
}

# Hard gate: the image has to fit in on-chip RAM, and it has to be the right
# kind of binary. A too-large or wrongly-linked FSBL fails silently on hardware.
verify_output()
{
	local elf="$BOOTLOADER_DIR/build/bootloader.elf"
	local bin="$BOOTLOADER_DIR/build/bootloader.bin"
	local limit used entry class flags rc=0

	[ -f "$elf" ] || efx_die 1 "build produced no $elf"
	[ -f "$bin" ] || efx_die 1 "build produced no $bin"

	efx_title "Verifying the bootloader image"

	limit=$(soc_define SYSTEM_RAM_A_SIZE)
	used=$(efx_size "$bin")
	if [ -z "$limit" ] || [ "$limit" -eq 0 ]; then
		efx_warn "SYSTEM_RAM_A_SIZE not found in soc.h — cannot check the size budget"
	elif [ "$used" -gt "$limit" ]; then
		efx_err "on-chip RAM: $used > $limit bytes — the bootloader does not fit"
		efx_err "shrink it (DEBUG?=no, -Os) or set EFX_FSBL_CFLAGS_EXTRA, or fall back to the vendor toolchain with --ide"
		rc=1
	else
		efx_ok "on-chip RAM: $used / $limit bytes ($(( used * 100 / limit ))% used)"
	fi

	class=$("$FSBL_BIN_DIR/${FSBL_PREFIX}readelf" -h "$elf" | awk -F: '/Class/ {gsub(/ /,"",$2); print $2}')
	entry=$("$FSBL_BIN_DIR/${FSBL_PREFIX}readelf" -h "$elf" | awk -F: '/Entry point/ {gsub(/ /,"",$2); print $2}')
	flags=$("$FSBL_BIN_DIR/${FSBL_PREFIX}readelf" -h "$elf" | awk -F: '/Flags/ {print $2}')

	local want_entry
	want_entry=$(soc_define SYSTEM_RAM_A_CTRL)

	[ "$class" = ELF32 ] \
		&& efx_ok "ELF class: $class" \
		|| { efx_err "ELF class is $class, expected ELF32"; rc=1; }

	if [ -n "$want_entry" ] && [ $((entry)) -eq $((want_entry)) ]; then
		efx_ok "entry point: $entry (on-chip RAM at $want_entry)"
	else
		efx_err "entry point is $entry, expected $want_entry (check $SAPPHIRE_DIR/linker/bootloader.ld)"
		rc=1
	fi

	efx_ok "ABI flags:$flags"
	efx_info "expected -march=$FSBL_MARCH -mabi=$FSBL_MABI"

	# Show the linker's own memory report — it is the authoritative view.
	if [ -f "$BOOTLOADER_DIR/build/bootloader.map" ]; then
		efx_info "map file: $BOOTLOADER_DIR/build/bootloader.map"
	fi

	return $rc
}

install_output()
{
	mkdir -p "$OUT_DIR"
	cp -f "$BOOTLOADER_DIR/build/bootloader.elf" \
	      "$BOOTLOADER_DIR/build/bootloader.bin" \
	      "$BOOTLOADER_DIR/build/bootloader.hex" \
	      "$OUT_DIR/" 2>/dev/null
	[ -f "$BOOTLOADER_DIR/build/bootloader.asm" ] && cp -f "$BOOTLOADER_DIR/build/bootloader.asm" "$OUT_DIR/"
	[ -f "$BOOTLOADER_DIR/build/bootloader.map" ] && cp -f "$BOOTLOADER_DIR/build/bootloader.map" "$OUT_DIR/"

	# The project lives on a filesystem without POSIX metadata, so freshness is
	# tracked by content hash rather than mtime.
	sha256sum "$OUT_DIR/bootloader.bin" | awk '{print $1}' > "$EFX_STATE_DIR/fsbl.sha256"

	efx_info "installed into $OUT_DIR"
}

next_steps()
{
	cat <<-EOF

	$(printf '%s' "$_C_BLD")Next:$(printf '%s' "$_C_OFF") the bootloader lives in the FPGA's on-chip RAM, so the bitstream
	has to carry it. Patch it in without re-running place & route:

	    efx fpga bram-update

	Then program the board:

	    efx flash spi
	EOF
}

# ------------------------------------------------------------------- verbs ---

case "$VERB" in
build|rebuild)
	check_layout
	[ $FORCE -eq 1 ] || efx_require_clean_state fsbl
	derive_isa
	toolchain_setup

	efx_lock_acquire "fsbl $VERB"
	trap 'efx_lock_release' EXIT

	efx_title "Building the FSBL ($EFX_FSBL_BSP_NAME, -march=$FSBL_MARCH -mabi=$FSBL_MABI)"
	backup_originals
	install_linux_config

	[ "$VERB" = rebuild ] && do_make clean
	do_make all || efx_die 1 "FSBL build failed"

	verify_output || efx_die 1 "FSBL failed verification — not installing"
	install_output
	next_steps
	;;

clean)
	check_layout
	derive_isa
	toolchain_setup
	efx_lock_acquire "fsbl clean"
	trap 'efx_lock_release' EXIT
	do_make clean
	rm -f "$EFX_STATE_DIR/last-fsbl.json"
	efx_info "cleaned $BOOTLOADER_DIR/build"
	;;

restore)
	[ -d "$BACKUP_DIR" ] || efx_die $EFX_EX_CONFIG "nothing to restore (no $BACKUP_DIR)"
	cp -f "$BACKUP_DIR/bootloaderConfig.h" "$BOOTLOADER_DIR/src/bootloaderConfig.h"
	cp -f "$BACKUP_DIR/soc.mk" "$SOC_MK"
	efx_info "restored the project's original bootloaderConfig.h and soc.mk"
	;;

status)
	exec "$EFX_DIR/scripts/efx-status.sh" --component fsbl
	;;

*)
	efx_die $EFX_EX_USAGE "unknown verb: $VERB (build|rebuild|clean|restore|status)"
	;;
esac
