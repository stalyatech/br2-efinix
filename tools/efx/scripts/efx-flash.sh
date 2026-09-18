#!/bin/bash
# efx flash — build the boot flash image and put it, or the bitstream, on the board.
#
#   efx flash image     assemble the SPI flash image: bitstream, OpenSBI, U-Boot,
#                       device tree, boot script and kernel at their offsets
#   efx flash sram      load the bitstream into the FPGA over JTAG. Volatile: a
#                       power cycle brings back whatever is in the flash, so this
#                       is the safe way to try a new bitstream
#   efx flash backup    read the first 16 MiB of the flash into a file
#   efx flash spi       write the flash image (backs the flash up first), then
#                       reset the FPGA so it boots from it. --part dtb,kernel
#                       writes only those slots (bitstream opensbi uboot dtb
#                       bootscr kernel) and skips the backup
#   efx flash reset     pulse CRESET_N: reconfigure from the flash, like power-up
#   efx flash list      removable block devices, for sdcard
#   efx flash sdcard    write sdcard.img to a removable device
#
# The flash image is Efinix's programming format: one byte per line as two hex
# digits, line N being flash address N, gaps filled with FF. efx builds it itself
# rather than through multi_image_merger.py, so it can check every slot.

set -u

: "${EFX_DIR:?must be run through tools/efx/efx}"
. "$EFX_DIR/lib/common.sh"
. "$EFX_DIR/lib/conf.sh"
efx_conf_load || exit $EFX_EX_CONFIG

VERB=${1:-list}
[ $# -gt 0 ] && shift

DEVICE=''
CONFIRM=''
NO_BACKUP=0
PARTS=''
while [ $# -gt 0 ]; do
	case "$1" in
	--device)    DEVICE=${2:-}; shift ;;
	--device=*)  DEVICE=${1#*=} ;;
	--confirm)   CONFIRM=${2:-}; shift ;;
	--confirm=*) CONFIRM=${1#*=} ;;
	--no-backup) NO_BACKUP=1 ;;
	--part)      PARTS=${2:-}; shift ;;
	--part=*)    PARTS=${1#*=} ;;
	-h|--help)
		sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*) efx_die $EFX_EX_USAGE "unknown option: $1" ;;
	esac
	shift
done

BOARD_PROFILE="Titanium Ti375C529 Dev Board"
FLASH_DIR="$EFX_STATE_DIR/flash"
FLASH_HEX="$FLASH_DIR/${FPGA_PROJECT}_flash.hex"
BITSTREAM_HEX="$EFX_PROJECT_DIR/outflow/${FPGA_PROJECT}.hex"
BITSTREAM_BIT="$EFX_PROJECT_DIR/outflow/${FPGA_PROJECT}.bit"

# DDR layout the boot script uses. The FDT and the decompression scratch area
# sit well above the kernel, so a growing kernel cannot run over them.
KERNEL_LOAD=0x08000000
FDT_LOAD=0x0C000000
KERNEL_COMP_SCRATCH=0x0D000000
SCRIPT_LOAD=0x08F00000          # must match CONFIG_BOOTCOMMAND

# Everything stays below 16 MiB: past that the flash needs 4-byte addressing,
# and a flash left in 4-byte mode by software breaks the FPGA's own x1
# configuration read at the next reset.
FLASH_3BYTE_LIMIT=$((0x1000000))

human_size() { numfmt --to=iec --suffix=B --format='%.1f' "$1" 2>/dev/null || echo "$1"; }

# Efinix's pgm/bin/ftdi_pgm.sh passes its arguments on as an unquoted $@, which
# splits the board profile name ("Titanium Ti375C529 Dev Board") into four
# words. Set up the same environment it does and call the programmer directly.
programmer()
{
	efx_efinity bash -c '
		export EFXPGM_HOME="$EFINITY_HOME/pgm" LD_LIBRARY_PATH="$EFINITY_HOME/lib" PYTHONNOUSERSITE=1
		export PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}$EFXPGM_HOME/bin"
		exec "$EFINITY_HOME/bin/python3" "$EFXPGM_HOME/bin/efx_pgm/ftdi_program.py" "$@"
	' programmer -b "$BOARD_PROFILE" "$@"
}

# The programmer drives the FTDI chip through libusb, which needs write access
# to the USB device node. Say exactly how to get it rather than failing inside
# the programmer with a stack trace.
require_usb_access()
{
	local d found=0
	for d in /sys/bus/usb/devices/*; do
		[ -f "$d/idVendor" ] && [ "$(cat "$d/idVendor")" = 0403 ] || continue
		grep -q "Ti375C529" "$d/product" 2>/dev/null || continue
		found=1
		local node
		node=$(printf '/dev/bus/usb/%03d/%03d' "$(cat "$d/busnum")" "$(cat "$d/devnum")")
		if [ ! -w "$node" ]; then
			efx_err "no write access to $node (the board's FTDI chip)"
			efx_err "install the Efinix udev rule once, then retry:"
			efx_err "  sudo cp $EFINITY_HOME/bin/80-efx-pgm.rules /etc/udev/rules.d/"
			efx_err "  sudo udevadm control --reload-rules && sudo udevadm trigger"
			exit $EFX_EX_CONFIG
		fi
	done
	[ $found -eq 1 ] || efx_die $EFX_EX_CONFIG "Ti375C529 dev board not found on USB — is it plugged in and powered?"
}

# ------------------------------------------------------------------- image ---

do_image()
{
	local img="$EFX_IMAGES_DIR"
	local sbi="$img/fw_jump.bin" uboot="$img/u-boot.bin" dtb="$img/linux.dtb" kernel="$img/Image"
	local f

	for f in "$BITSTREAM_HEX" "$sbi" "$uboot" "$dtb" "$kernel"; do
		[ -f "$f" ] || efx_die $EFX_EX_CONFIG "missing $f — build it first (efx fpga build / efx image build)"
	done

	# The FSBL copies a fixed number of bytes from fixed offsets; those have to
	# be the offsets written here, and the images have to fit in what it copies.
	local cfg sbi_flash sbi_copy ub_flash ub_copy
	cfg=$(efx_fsbl_config)
	sbi_flash=$(efx_soc_define "$cfg" OPENSBI_FLASH)
	sbi_copy=$(efx_soc_define "$cfg" OPENSBI_SIZE)
	ub_flash=$(efx_soc_define "$cfg" UBOOT_SBI_FLASH)
	ub_copy=$(efx_soc_define "$cfg" UBOOT_SIZE)
	[ -n "$sbi_flash" ] && [ -n "$sbi_copy" ] && [ -n "$ub_flash" ] && [ -n "$ub_copy" ] \
		|| efx_die $EFX_EX_CONFIG "cannot read the flash offsets from $cfg"
	if [ $((sbi_flash)) -ne $((FLASH_OPENSBI_OFFSET)) ] || [ $((ub_flash)) -ne $((FLASH_UBOOT_OFFSET)) ]; then
		efx_err "the FSBL and efx.conf disagree on where the firmware lives:"
		efx_err "  OpenSBI  FSBL $sbi_flash   efx.conf $FLASH_OPENSBI_OFFSET"
		efx_err "  U-Boot   FSBL $ub_flash   efx.conf $FLASH_UBOOT_OFFSET"
		efx_die $EFX_EX_CONFIG "fix one of them ($cfg or efx.conf)"
	fi
	local sbi_end=$(( sbi_flash + sbi_copy )) ub_end=$(( ub_flash + ub_copy ))
	[ $sbi_end -le $((FLASH_UBOOT_OFFSET)) ] || sbi_end=$((FLASH_UBOOT_OFFSET))
	[ $ub_end -le $((FLASH_DTB_OFFSET)) ] || ub_end=$((FLASH_DTB_OFFSET))
	# CONFIG_BOOTCOMMAND reads 64 KiB of script, whatever follows it
	local scr_end=$(( FLASH_BOOTSCR_OFFSET + 0x10000 ))
	[ $scr_end -le $((FLASH_KERNEL_OFFSET)) ] || scr_end=$((FLASH_KERNEL_OFFSET))

	mkdir -p "$FLASH_DIR"
	efx_title "Assembling the boot flash image"

	# Compressed kernel: an initramfs Image is over 8 MiB, and the flash has to
	# stay below 16 MiB (see FLASH_3BYTE_LIMIT). booti inflates it.
	gzip -9 -n -c "$kernel" > "$FLASH_DIR/Image.gz"
	local ksize dsize
	ksize=$(efx_size "$FLASH_DIR/Image.gz")
	dsize=$(efx_size "$dtb")

	cat > "$FLASH_DIR/boot.cmd" <<-EOF
	# ti375_oob: boot Linux from the SPI flash. Generated by efx flash image.
	echo "ti375_oob: loading Linux from SPI flash"
	sf probe 0
	sf read $FDT_LOAD $FLASH_DTB_OFFSET $(printf '0x%x' "$dsize")
	sf read $KERNEL_LOAD $FLASH_KERNEL_OFFSET $(printf '0x%x' "$ksize")
	setenv kernel_comp_addr_r $KERNEL_COMP_SCRATCH
	setenv kernel_comp_size $(printf '%x' "$ksize")
	setenv fdt_high 0xffffffff
	booti $KERNEL_LOAD - $FDT_LOAD
	EOF
	local mkimage="$EFX_BUILD_DIR/host/bin/mkimage"
	[ -x "$mkimage" ] || mkimage=$(command -v mkimage)
	"$mkimage" -A riscv -O linux -T script -C none -n "ti375_oob boot" \
		-d "$FLASH_DIR/boot.cmd" "$FLASH_DIR/boot.scr" > /dev/null \
		|| efx_die 1 "mkimage failed to build boot.scr"

	python3 - "$FLASH_HEX" "$FLASH_3BYTE_LIMIT" \
		"bitstream:$FLASH_BITSTREAM_OFFSET:$FLASH_OPENSBI_OFFSET:$BITSTREAM_HEX" \
		"opensbi:$FLASH_OPENSBI_OFFSET:$sbi_end:$sbi" \
		"uboot:$FLASH_UBOOT_OFFSET:$ub_end:$uboot" \
		"dtb:$FLASH_DTB_OFFSET:$FLASH_BOOTSCR_OFFSET:$dtb" \
		"bootscr:$FLASH_BOOTSCR_OFFSET:$scr_end:$FLASH_DIR/boot.scr" \
		"kernel:$FLASH_KERNEL_OFFSET:$FLASH_3BYTE_LIMIT:$FLASH_DIR/Image.gz" <<-'PY' || exit 1
		import sys

		out, limit = sys.argv[1], int(sys.argv[2], 0)
		parts = []
		for spec in sys.argv[3:]:
		    name, start, end, path = spec.split(':', 3)
		    start, end = int(start, 0), int(end, 0)
		    if path.endswith('.hex'):
		        # Efinix bitstream hex: one byte per line
		        data = bytes(int(l, 16) for l in open(path) if l.strip())
		    else:
		        data = open(path, 'rb').read()
		    parts.append((name, start, end, data))

		bad = False
		print(f"  {'image':<10} {'offset':>10} {'size':>10} {'slot':>10}  use")
		for name, start, end, data in parts:
		    slot = end - start
		    pct = 100 * len(data) // slot
		    flag = '' if len(data) <= slot else '   <-- DOES NOT FIT'
		    print(f"  {name:<10} 0x{start:08x} {len(data):>10} {slot:>10}  {pct:3d}%{flag}")
		    bad |= len(data) > slot
		if bad:
		    sys.exit("an image overruns its flash slot; the next one would be overwritten")

		top = max(s + len(d) for _, s, _, d in parts)
		if top > limit:
		    sys.exit(f"image reaches 0x{top:x}, past the 16 MiB 3-byte addressing limit")

		flash = bytearray(b'\xff' * top)
		for _, start, _, data in parts:
		    flash[start:start + len(data)] = data
		with open(out, 'w') as fh:
		    fh.write(''.join('%02X\n' % b for b in flash))
		open(out[:-4] + '.bin', 'wb').write(flash)
		print(f"\n  flash image: {top} bytes (0x{top:x}), {top * 100 // limit}% of the first 16 MiB")
	PY

	efx_info "wrote $FLASH_HEX"
	efx_info "boot script: $FLASH_DIR/boot.cmd"
}

# ------------------------------------------------------------ programming ---

# The Ti375C529 dev board wires the FTDI chip to the FPGA's JTAG port only, not
# to the configuration flash (its board profile lists "JTAG" and "SPI Active
# using JTAG Bridge"; the SS/CCK pins are unassigned). The flash is reached by
# first loading Efinix's JTAG-to-SPI bridge design into the FPGA, then talking
# to the flash through it. The bridge image is picked by the JTAG IDCODE.
BRIDGE_IDCODE=${EFX_BRIDGE_IDCODE:-006A0A79}     # Ti375C529
BRIDGE_BIT="$EFINITY_HOME/pgm/fli/titanium/u${BRIDGE_IDCODE}.bit"

load_bridge()
{
	[ -f "$BRIDGE_BIT" ] || efx_die $EFX_EX_CONFIG "no JTAG bridge image at $BRIDGE_BIT"
	efx_info "loading the JTAG-to-SPI bridge ($(basename "$BRIDGE_BIT"))"
	efx_run_step flash bridge -- programmer -m jtag "$BRIDGE_BIT" \
		|| efx_die 1 "could not load the JTAG bridge"
}

# Pulse CRESET_N (FTDI channel B, bit 4 on this board) so the FPGA reloads its
# configuration from the flash, as it would at power-up.
reset_fpga()
{
	efx_info "pulsing CRESET_N: the FPGA reconfigures from the flash"
	efx_efinity bash -c '
		export LD_LIBRARY_PATH="$EFINITY_HOME/lib" PYTHONNOUSERSITE=1
		exec "$EFINITY_HOME/bin/python3" - <<-"PY"
			import time
			from pyftdi.gpio import GpioAsyncController
			CRESET_N = 1 << 4
			gpio = GpioAsyncController()
			gpio.configure("ftdi://0x0403:0x6011/2", direction=CRESET_N, initial=CRESET_N)
			gpio.write(0)
			time.sleep(0.3)
			gpio.write(CRESET_N)
			time.sleep(0.05)
			gpio.set_direction(CRESET_N, 0)     # let the board pull-up hold it
			gpio.close()
		PY
	'
}

do_sram()
{
	[ -f "$BITSTREAM_BIT" ] || efx_die $EFX_EX_CONFIG "no bitstream at $BITSTREAM_BIT — run 'efx fpga build'"
	require_usb_access
	efx_lock_acquire "flash sram"
	trap 'efx_lock_release' EXIT
	efx_title "Loading $(basename "$BITSTREAM_BIT") into the FPGA over JTAG (volatile)"
	efx_run_step flash sram -- programmer -m jtag "$BITSTREAM_BIT"
}

# read_backup: the bridge must already be loaded.
read_backup()
{
	local out="$FLASH_DIR/backup-$(date +%Y%m%d-%H%M%S).hex"
	mkdir -p "$FLASH_DIR"
	efx_title "Reading the first 16 MiB of the boot flash"
	efx_run_step flash backup -- \
		programmer -m jtag_bridge --jtag_bridge_mode read \
			--address 0 --num_bytes "$FLASH_3BYTE_LIMIT" -o "$out" \
		|| return 1
	[ "$(efx_size "$out")" -ge $(( FLASH_3BYTE_LIMIT * 3 )) ] || { efx_err "backup is short: $out"; return 1; }
	efx_info "backup: $out ($(human_size "$(efx_size "$out")"))"
}

do_backup()
{
	require_usb_access
	efx_lock_acquire "flash backup"
	trap 'efx_lock_release' EXIT
	load_bridge
	read_backup || efx_die 1 "flash read failed"
	reset_fpga
}

do_spi()
{
	[ -f "$FLASH_HEX" ] || efx_die $EFX_EX_CONFIG "no flash image — run 'efx flash image' first"
	require_usb_access
	efx_lock_acquire "flash spi"
	trap 'efx_lock_release' EXIT

	# --part: cut each named slot out of the assembled image, so a kernel or
	# device tree change costs seconds instead of rewriting all 16 MiB.
	local -a jobs=()
	if [ -n "$PARTS" ]; then
		local part start end piece
		for part in ${PARTS//,/ }; do
			case "$part" in
			bitstream) start=$FLASH_BITSTREAM_OFFSET end=$FLASH_OPENSBI_OFFSET ;;
			opensbi)   start=$FLASH_OPENSBI_OFFSET   end=$FLASH_UBOOT_OFFSET ;;
			uboot)     start=$FLASH_UBOOT_OFFSET     end=$FLASH_DTB_OFFSET ;;
			dtb)       start=$FLASH_DTB_OFFSET       end=$FLASH_BOOTSCR_OFFSET ;;
			bootscr)   start=$FLASH_BOOTSCR_OFFSET   end=$((FLASH_BOOTSCR_OFFSET + 0x10000)) ;;
			kernel)    start=$FLASH_KERNEL_OFFSET    end=$FLASH_3BYTE_LIMIT ;;
			*) efx_die $EFX_EX_USAGE "unknown part '$part' (bitstream opensbi uboot dtb bootscr kernel)" ;;
			esac
			piece="$FLASH_DIR/part-$part.hex"
			# Trailing FF is left out (the erase leaves it that way), then the
			# piece is padded back to whole 4 KiB sectors: the bridge's on-chip
			# CRC check refuses very short ranges ("cannot enter CRC mode").
			python3 - "${FLASH_HEX%.hex}.bin" "$((start))" "$((end))" "$piece" <<-'PY' || exit 1
				import sys
				src, start, end, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
				data = open(src, 'rb').read()[start:end].rstrip(b'\xff')
				if not data:
				    sys.exit(f"{out}: slot is empty in the image")
				data += b'\xff' * (-len(data) % 4096)
				open(out, 'w').write(''.join('%02X\n' % b for b in data))
			PY
			jobs+=("$part:$(printf '0x%x' $((start))):$piece")
		done
		NO_BACKUP=1
	else
		jobs=("image:0x0:$FLASH_HEX")
	fi

	load_bridge
	if [ $NO_BACKUP -eq 0 ]; then
		read_backup || efx_die 1 "backup failed; not writing (pass --no-backup to skip it)"
	fi

	# "all": erase the range each piece covers, write it, then have the bridge
	# CRC it on chip (the programmer's default onchipx2 check).
	local job name addr file
	for job in "${jobs[@]}"; do
		IFS=: read -r name addr file <<<"$job"
		efx_title "Writing $name at $addr through the JTAG bridge"
		efx_run_step flash spi -- \
			programmer -m jtag_bridge --jtag_bridge_mode all --address "$addr" "$file" \
			|| efx_die 1 "flash write failed — the FPGA still runs the bridge; run 'efx flash spi' again"
	done
	reset_fpga
}

do_reset()
{
	require_usb_access
	reset_fpga
}

# ---------------------------------------------------------------- sdcard ---

device_info()
{
	local dev=$1 name model size removable mounted
	name=$(basename "$dev")

	[ -b "$dev" ] || { echo "not a block device"; return 1; }
	[ -d "/sys/block/$name" ] || { echo "not a whole disk (partitions cannot be flashed)"; return 1; }

	model=$(cat "/sys/block/$name/device/model" 2>/dev/null | tr -s ' ' '_' | sed 's/_$//')
	size=$(lsblk -bdno SIZE "$dev" 2>/dev/null)
	removable=$(cat "/sys/block/$name/removable" 2>/dev/null || echo 0)
	mounted=$(lsblk -no MOUNTPOINTS "$dev" 2>/dev/null | grep -c . || true)

	printf '%s|%s|%s|%s\n' "${model:-unknown}" "${size:-0}" "$removable" "$mounted"
}

do_list()
{
	efx_title "Block devices"
	printf '%-12s %-24s %-10s %-10s %s\n' DEVICE MODEL SIZE REMOVABLE MOUNTED
	local dev info model size removable mounted
	for dev in /dev/sd? /dev/mmcblk? /dev/nvme?n?; do
		[ -b "$dev" ] || continue
		info=$(device_info "$dev") || continue
		IFS='|' read -r model size removable mounted <<<"$info"
		printf '%-12s %-24s %-10s %-10s %s\n' \
			"$dev" "$model" "$(human_size "$size")" \
			"$([ "$removable" = 1 ] && echo yes || echo NO)" \
			"$([ "$mounted" -gt 0 ] && echo yes || echo no)"
	done
}

do_sdcard()
{
	local img="$EFX_IMAGES_DIR/sdcard.img"

	[ "$ROOTFS_MODE" = sdcard ] || efx_die $EFX_EX_CONFIG \
		"ROOTFS_MODE is '$ROOTFS_MODE' — there is no sdcard.img to write. Set ROOTFS_MODE=sdcard and rebuild."
	[ -f "$img" ] || efx_die $EFX_EX_CONFIG "no image at $img — run 'efx image build' first"
	[ -n "$DEVICE" ] || efx_die $EFX_EX_USAGE "--device is required (see 'efx flash list')"

	local info model size removable mounted expect
	info=$(device_info "$DEVICE") || efx_die 1 "$DEVICE: $info"
	IFS='|' read -r model size removable mounted <<<"$info"

	[ "$removable" = 1 ] || efx_die 1 "$DEVICE ($model) is not removable — refusing. This looks like a fixed disk."
	[ "$mounted" -gt 0 ] && efx_die 1 "$DEVICE has mounted partitions — unmount them first"

	expect="${model}:$(human_size "$size")"
	if [ "$CONFIRM" != "$expect" ]; then
		cat >&2 <<-EOF

		About to overwrite $DEVICE — everything on it will be lost.

		    device : $DEVICE
		    model  : $model
		    size   : $(human_size "$size")
		    image  : $img ($(human_size "$(efx_size "$img")"))

		Re-run with the device named back to me:

		    efx flash sdcard --device $DEVICE --confirm '$expect'
		EOF
		exit 1
	fi

	efx_lock_acquire "flash sdcard"
	trap 'efx_lock_release' EXIT
	efx_run_step flash sdcard -- dd if="$img" of="$DEVICE" bs=4M conv=fsync status=progress
	sync
}

case "$VERB" in
image)  do_image ;;
sram)   do_sram ;;
backup) do_backup ;;
reset)  do_reset ;;
spi)    do_spi ;;
list)   do_list ;;
sdcard) do_sdcard ;;
*)      efx_die $EFX_EX_USAGE "unknown verb: $VERB (image|sram|backup|spi|reset|list|sdcard)" ;;
esac
