#!/bin/bash
# efx fpga — drive the Efinity toolchain from the command line.
#
# How each boot image gets into the bitstream:
#
#   hard SoC FSBL   16 KiB on-chip RAM inside the hardened block. The Interface
#                   Designer loads it from OCR_FILE_PATH in <project>.peri.xml
#                   (sw/boot/bootloader.hex) into the periphery
#                   configuration, so a new FSBL needs the interface and pgm
#                   stages of 'efx fpga build'. 'verify-fsbl' proves which FSBL a
#                   built bitstream carries.
#
#   FCU firmware    The soft SoC's RAM is fabric BRAM. efx_bram_edit (called
#                   efx_bram_update before Efinity 2026.1) rewrites it inside the
#                   finished bitstream: seconds, no synthesis or place & route.
#
# Every Efinity tool runs through efx_efinity (lib/common.sh), in a clean
# environment: a virtualenv or ROS setup in the calling shell breaks its Python.

set -u

: "${EFX_DIR:?must be run through tools/efx/efx}"
. "$EFX_DIR/lib/common.sh"
. "$EFX_DIR/lib/conf.sh"
efx_conf_load || exit $EFX_EX_CONFIG

VERB=${1:-status}
[ $# -gt 0 ] && shift

FLOW=compile
while [ $# -gt 0 ]; do
	case "$1" in
	--flow)   FLOW=${2:-compile}; shift ;;
	--flow=*) FLOW=${1#*=} ;;
	-h|--help)
		cat <<-EOF
		Usage: efx fpga <verb> [options]

		Verbs:
		  check         Check that this Efinity can read the project (read-only)
		  memories      List the memories efx_bram_update can initialise
		  bram-update   Patch the FCU firmware into the existing bitstream (seconds)
		  verify-fsbl   Check that the built bitstream carries the current FSBL
		  build         Run the Efinity flow  (--flow map|pnr|pgm|compile, default compile)
		  pgm           Regenerate the programming .hex from the current bitstream
		  status        Show the bitstream artefacts

		This needs EFINITY_HOME (currently: ${EFINITY_HOME:-<unset>}).
		EOF
		exit 0
		;;
	*) efx_die $EFX_EX_USAGE "unknown option: $1" ;;
	esac
	shift
done

PRJ="$EFX_PROJECT_DIR/${FPGA_PROJECT}.xml"
OUTFLOW="$EFX_PROJECT_DIR/outflow"
WORK_PNR="$EFX_PROJECT_DIR/work_pnr"
RAMINFO="$OUTFLOW/${FPGA_PROJECT}.raminfo.pb"
LBF="$WORK_PNR/${FPGA_PROJECT}.lbf"
FSBL_BIN="$EFX_FSBL_DIR/bootloader.bin"
FSBL_HEX="$EFX_FSBL_DIR/bootloader.hex"
FAMILY=Titanium

need_efinity()
{
	[ -n "$EFINITY_HOME" ] && [ -x "$EFINITY_HOME/bin/efx_run" ] \
		|| efx_die $EFX_EX_CONFIG "Efinity not found at '${EFINITY_HOME:-}' — set EFINITY_HOME in efx.conf"
	[ -f "$PRJ" ] || efx_die $EFX_EX_CONFIG "Efinity project not found: $PRJ"
	BRAM_TOOL="$EFINITY_HOME/bin/efx_bram_edit"
	[ -x "$BRAM_TOOL" ] || BRAM_TOOL="$EFINITY_HOME/bin/efx_bram_update"
}

# Efinity's own project XML carries the version it was authored with. A mismatch
# is not automatically fatal — the tools warn about unknown schema elements and
# usually carry on — but it is the first thing to suspect when a flow misbehaves.
version_note()
{
	local prj_ver tool_ver
	prj_ver=$(sed -n 's/.*sw_version="\([^"]*\)".*/\1/p' "$PRJ" | head -1)
	tool_ver=$(sed -n 's/^base_version *= *//p' "$EFINITY_HOME/MANIFEST" 2>/dev/null | head -1)

	if [ -n "$prj_ver" ] && [ "${prj_ver%%.*}.${prj_ver#*.}" != "$tool_ver" ] \
	   && [ "${prj_ver%.*}" != "${tool_ver%.*}" ]; then
		efx_warn "project was authored with Efinity $prj_ver, this install is $tool_ver"
		efx_warn "expect 'no declaration found for element' schema warnings; they are usually harmless"
	fi
}

# One "## ramnet <logical memory>" line per initialisable memory.
bram_read()
{
	local out
	out=$(efx_efinity "$BRAM_TOOL" -j "$PRJ" -i "$RAMINFO" -f "$FAMILY" -m read 2>/dev/null)
	if grep -q '^## ramnet' <<<"$out"; then
		printf '%s\n' "$out"
		return
	fi
	# efx_bram_edit (2026.1) prints nothing in read mode. The logical memory
	# names are plain strings in the protobuf; the "__D$n" entries are the
	# physical blocks each one was split into.
	strings -n 8 "$RAMINFO" | grep -o '[A-Za-z_][A-Za-z0-9_/.]*/[A-Za-z0-9_/.$]*' \
		| grep -v '__D\$' | sort -u | sed 's/^/## ramnet /'
}

case "$VERB" in
check)
	need_efinity
	efx_title "Efinity installation"
	efx_info "EFINITY_HOME  $EFINITY_HOME"
	efx_info "version       $(sed -n 's/^base_version *= *//p' "$EFINITY_HOME/MANIFEST" | head -1)"
	efx_info "project       $PRJ"
	efx_info "authored with $(sed -n 's/.*sw_version="\([^"]*\)".*/\1/p' "$PRJ" | head -1)"
	version_note

	efx_title "Reading the project (read-only)"
	if [ -f "$RAMINFO" ]; then
		# Collect the output before matching: `| grep -q` would close the pipe on
		# the first hit and, under pipefail, turn the producer's SIGPIPE into a
		# failed check.
		local_mems=$(bram_read | grep -c '^## ramnet' || true)
		if [ "${local_mems:-0}" -gt 0 ]; then
			efx_ok "the toolchain can read this project's bitstream database ($local_mems memories)"
		else
			efx_err "$(basename "$BRAM_TOOL") could not read $RAMINFO"
			exit 1
		fi
	else
		efx_warn "no $RAMINFO — run a full Efinity build first ('efx fpga build')"
	fi
	;;

memories)
	need_efinity
	[ -f "$RAMINFO" ] || efx_die 1 "no $RAMINFO — the project has not been built"
	efx_title "Memories that can be initialised in the bitstream"
	bram_read | grep '^## ramnet' | sed 's/^## ramnet /  /'
	;;

bram-update)
	need_efinity
	[ -f "$RAMINFO" ] || efx_die 1 "no $RAMINFO — the project has not been built by Efinity"
	[ -f "$LBF" ]     || efx_die 1 "no logical bitstream at $LBF — run 'efx fpga build' first"

	# What goes into the FCU's RAM: its firmware when the hard SoC runs the
	# FSBL, or the FSBL itself in the older layout where the FCU booted Linux.
	if [ "$FSBL_HOST" = hard ]; then
		src=$FCU_FIRMWARE
		case "$src" in /*) ;; *) src="$EFX_PROJECT_DIR/$src" ;; esac
		[ -f "$src" ] || efx_die $EFX_EX_CONFIG "no FCU firmware at $src (FCU_FIRMWARE)"
	else
		src=$FSBL_BIN
		[ -f "$src" ] || efx_die $EFX_EX_CONFIG "no FSBL yet — run 'efx fsbl build' first"
	fi

	efx_lock_acquire "fpga bram-update"
	trap 'efx_lock_release' EXIT

	local_out="$OUTFLOW/${FPGA_PROJECT}.bram_updated.lbf"
	efx_title "Patching $(basename "$src") into the FCU RAM"
	version_note

	# binGen.py splits the flat image into the eight byte-lane symbol files the
	# fabric RAM is built from. It finds Efinity through EFINITY_HOME.
	local_tool="$EFX_PROJECT_DIR/embedded_sw/EfxSapphireFCU/tool/binGen.py"
	[ -f "$local_tool" ] || efx_die 1 "binGen.py not found at $local_tool"

	efx_run_step fpga bingen -- \
		env -C "$(dirname "$local_tool")" EFINITY_HOME="$EFINITY_HOME" \
			python3 binGen.py -b "$src" -f 1 -s 16384 || exit $?

	# Hand each symbol file to the matching logical memory.
	mem_args=()
	for i in 0 1 2 3 4 5 6 7; do
		sym="$EFX_PROJECT_DIR/ip/EfxSapphireFCU/EfxSapphireSoc.v_toplevel_system_ramA_logic_ram_symbol${i}.bin"
		[ -f "$sym" ] || efx_die 1 "binGen.py did not produce $sym"
		mem_args+=(-b "u_EfxSapphireFCU/u_EfxSapphireSoc/system_ramA_logic/ram_symbol${i},$sym")
	done

	efx_run_step fpga bram-update -- \
		efx_efinity "$BRAM_TOOL" \
			-j "$PRJ" -i "$RAMINFO" -l "$LBF" -o "$local_out" \
			-f "$FAMILY" -m update "${mem_args[@]}" || exit $?

	efx_info "updated logical bitstream: $local_out"
	efx_info "now run 'efx fpga pgm' to turn it into a programming image"
	;;

verify-fsbl)
	# The Interface Designer writes the OCR image into the periphery bitstream
	# as eight PCR chains, bit c of byte n going to chain c, bit 7-(n%8) of byte
	# n/8 (pt/bin/tx375_device/soc/writer/logical_periphery.py). Rebuild those
	# chains from bootloader.hex and compare.
	LPF="$OUTFLOW/${FPGA_PROJECT}.lpf"
	[ -f "$LPF" ]      || efx_die 1 "no $LPF — run 'efx fpga build'"
	[ -f "$FSBL_HEX" ] || efx_die $EFX_EX_CONFIG "no $FSBL_HEX — run 'efx fsbl build'"
	efx_title "Checking the FSBL in $(basename "$LPF")"
	python3 - "$LPF" "$FSBL_HEX" <<-'PY'
		import re, sys
		lpf, hexfile = sys.argv[1], sys.argv[2]
		text = open(lpf).read()
		i = text.find('<efxpt:instance id="SOC_0:SOC_CFG" type="soc:SOC_CFG">')
		if i < 0:
		    sys.exit("the periphery bitstream has no on-chip RAM image: OCR_FILE_PATH is empty")
		block = text[i:text.find('</efxpt:instance>', i)]
		chains = dict(re.findall(r'name="PCR_UNSUPPORTED(\d)" value="([0-9A-F]*)"', block))

		ram = bytearray(16384)
		for line in open(hexfile):
		    line = line.strip()
		    if line.startswith(':') and line[7:9] == '00':
		        n, addr = int(line[1:3], 16), int(line[3:7], 16)
		        ram[addr:addr + n] = bytes.fromhex(line[9:9 + 2 * n])
		want = [bytearray(2048) for _ in range(8)]
		for n, byte in enumerate(ram):
		    for c in range(8):
		        if byte >> c & 1:
		            want[c][n // 8] |= 1 << (7 - n % 8)

		if all(chains.get(str(c)) == want[c].hex().upper() for c in range(8)):
		    print("  ok  the bitstream carries this FSBL")
		else:
		    sys.exit("the bitstream carries a different FSBL — rebuild it ('efx fpga build')")
	PY
	;;

build)
	need_efinity
	efx_lock_acquire "fpga build ($FLOW)"
	trap 'efx_lock_release' EXIT

	efx_title "Efinity flow: $FLOW"
	version_note
	efx_warn "synthesis and place & route on a Ti375C529 take a long time"

	cd "$EFX_PROJECT_DIR" || exit 1
	efx_run_step fpga build -- efx_efinity efx_run --prj "$PRJ" -f "$FLOW"
	;;

pgm)
	need_efinity
	efx_lock_acquire "fpga pgm"
	trap 'efx_lock_release' EXIT

	src="$OUTFLOW/${FPGA_PROJECT}.bram_updated.lbf"
	[ -f "$src" ] || src="$WORK_PNR/${FPGA_PROJECT}.lbf"
	[ -f "$src" ] || efx_die 1 "no logical bitstream to package"

	efx_title "Generating the programming image from $(basename "$src")"
	efx_run_step fpga pgm -- \
		efx_efinity efx_pgm \
			--source "$src" \
			--dest "$OUTFLOW/${FPGA_PROJECT}.hex" \
			--device "$FPGA_DEVICE" \
			--family "$FAMILY" \
			--periph "$OUTFLOW/${FPGA_PROJECT}.lpf" \
			--mode active
	;;

status)
	exec "$EFX_DIR/scripts/efx-status.sh" --component fpga
	;;

*)
	efx_die $EFX_EX_USAGE "unknown verb: $VERB (check|memories|bram-update|verify-fsbl|build|pgm|status)"
	;;
esac
