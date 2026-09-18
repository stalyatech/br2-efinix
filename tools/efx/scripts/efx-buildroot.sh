#!/bin/bash
# efx opensbi|uboot|kernel|image — drive the Buildroot targets.
#
# One script for four components: they differ only in which Buildroot package
# they poke and which artefacts they produce. Everything runs inside $BUILD_DIR
# against the out-of-tree Buildroot checkout that `efx config configure` made.

set -u

: "${EFX_DIR:?must be run through tools/efx/efx}"
. "$EFX_DIR/lib/common.sh"
. "$EFX_DIR/lib/conf.sh"
efx_conf_load || exit $EFX_EX_CONFIG

COMPONENT=${1:-}
[ $# -gt 0 ] && shift
VERB=${1:-build}
[ $# -gt 0 ] && shift

FORCE=0
while [ $# -gt 0 ]; do
	case "$1" in
	--force) FORCE=1 ;;
	-h|--help)
		echo "Usage: efx <opensbi|uboot|kernel|image> <build|rebuild|clean|distclean|savedefconfig|status> [--force]"
		exit 0
		;;
	*) efx_die $EFX_EX_USAGE "unknown option: $1" ;;
	esac
	shift
done

case "$COMPONENT" in
opensbi) PKG=opensbi ;;
uboot)   PKG=uboot ;;
kernel)  PKG=linux ;;
image)   PKG='' ;;
*) efx_die $EFX_EX_USAGE "unknown component: $COMPONENT" ;;
esac

# make(1) invocation shared by every verb. Buildroot is built out of tree, so
# O= and BR2_EXTERNAL have to be repeated on every call.
br_make()
{
	env -C "$EFX_BUILD_DIR" \
		make -C "$EFX_BUILDROOT_DIR" O="$EFX_BUILD_DIR" BR2_EXTERNAL="$EFX_REPO_DIR" "$@"
}

report_artifacts()
{
	efx_title "Artifacts"
	"$EFX_DIR/scripts/efx-status.sh" --component "$COMPONENT"
}

# The FSBL copies fixed-size slices out of SPI flash into DDR. If an image grows
# past its slot the copy is silently truncated and the board hangs with no
# diagnostic, so check the budget at build time where it is still cheap to fix.
#
# The sizes come from the same header the bootloader is compiled against, so the
# two can never disagree.
check_flash_budget()
{
	local cfg artifact size_key img limit size
	cfg=$(efx_fsbl_config)

	case "$COMPONENT" in
	opensbi) img="$EFX_IMAGES_DIR/fw_jump.bin"; size_key=OPENSBI_SIZE ;;
	uboot)   img="$EFX_IMAGES_DIR/u-boot.bin";  size_key=UBOOT_SIZE ;;
	*) return 0 ;;
	esac

	[ -f "$cfg" ] && [ -f "$img" ] || return 0

	# The last definition wins: the stock header defines each name twice, RV64
	# first and RV32 in the #else branch; a board header defines it once.
	limit=$(awk -v k="$size_key" '
		{ sub(/\r$/, "") }
		$1 == "#define" && $2 == k { v = $3 }
		END { print v }
	' "$cfg")
	[ -n "$limit" ] || return 0

	size=$(efx_size "$img")
	if [ "$size" -gt $((limit)) ]; then
		efx_err "$(basename "$img") is $size bytes but the flash slot ($size_key) is $((limit))"
		efx_err "the FSBL would copy a truncated image — enlarge the slot in $cfg and reflash, or shrink the build"
		return 1
	fi

	efx_ok "flash budget: $(basename "$img") $size / $((limit)) bytes ($(( size * 100 / limit ))% of $size_key)"
	return 0
}

# genimage failing to build the FAT boot partition does not fail the Buildroot
# build: post_create_fs.sh does not propagate the error, so `make` exits 0 with no
# sdcard.img. Check for the artefact directly rather than trusting the exit code.
check_sdcard_image()
{
	[ "$COMPONENT" = image ] || return 0
	[ "$ROOTFS_MODE" = sdcard ] || return 0
	[ -f "$EFX_IMAGES_DIR/sdcard.img" ] && return 0

	efx_err "the build finished but produced no sdcard.img"
	if ! command -v mcopy >/dev/null 2>&1; then
		efx_err "mcopy is not installed — genimage cannot populate the FAT boot partition"
		efx_err "note that Ubuntu's mtools is also known-broken for this; docs/known_issues.md"
		efx_err "says to build 4.0.44 from source:"
		efx_err "  wget http://ftp.gnu.org/gnu/mtools/mtools-4.0.44.tar.gz && tar -xf mtools-4.0.44.tar.gz"
		efx_err "  cd mtools-4.0.44 && ./configure && make && sudo make install"
	else
		efx_err "check the genimage output in the log above"
	fi
	return 1
}

# The kernel and U-Boot get their configuration from fragment files listed in
# .config. Point at them so the GUI (and the user) know what to edit instead of
# reaching for menuconfig, which cannot run in a browser.
show_config_sources()
{
	local key=$1 files
	files=$(sed -n "s/^${key}=\"\(.*\)\"$/\1/p" "$EFX_BUILD_DIR/.config" 2>/dev/null)
	[ -n "$files" ] || return 0

	efx_title "Configuration fragments (edit these, then rebuild)"
	local f
	for f in $files; do
		# Expand Buildroot's own variable reference.
		f=${f//\$(BR2_EXTERNAL_EFINIX_PATH)/$EFX_REPO_DIR}
		printf '  %s\n' "$f"
	done
}

case "$VERB" in
build|rebuild)
	efx_require_configured
	[ $FORCE -eq 1 ] || efx_require_clean_state "$COMPONENT"
	efx_lock_acquire "$COMPONENT $VERB"
	trap 'efx_lock_release' EXIT

	if [ "$COMPONENT" = image ]; then
		# A full build: everything the target filesystem needs, then the images.
		efx_title "Building the root filesystem and images (-j$EFX_JOBS)"
		efx_run_step image "$VERB" -- br_make -j"$EFX_JOBS" || exit $?
	else
		efx_title "Building $COMPONENT ($PKG)"
		if [ "$VERB" = rebuild ]; then
			efx_run_step "$COMPONENT" rebuild -- br_make "${PKG}-rebuild" || exit $?
		else
			efx_run_step "$COMPONENT" build -- br_make "$PKG" || exit $?
		fi
		# Buildroot copies firmware into images/ during the target-finalize step,
		# so a package-only rebuild has to be followed by the image refresh for
		# the artefacts to actually appear.
		efx_run_step "$COMPONENT" install -- br_make "${PKG}-install" || true
	fi

	report_artifacts
	check_flash_budget || exit 1
	check_sdcard_image || exit 1
	;;

clean)
	efx_require_configured
	efx_lock_acquire "$COMPONENT clean"
	trap 'efx_lock_release' EXIT

	if [ "$COMPONENT" = image ]; then
		efx_run_step image clean -- br_make clean
	else
		efx_run_step "$COMPONENT" clean -- br_make "${PKG}-dirclean"
	fi
	rm -f "$EFX_STATE_DIR/last-$COMPONENT.json"
	efx_info "$COMPONENT cleaned — the next build starts from scratch"
	;;

distclean)
	efx_require_configured
	efx_lock_acquire "$COMPONENT distclean"
	trap 'efx_lock_release' EXIT
	efx_warn "removing the whole build output, including the toolchain"
	efx_run_step "$COMPONENT" distclean -- br_make clean
	rm -f "$EFX_STATE_DIR"/last-*.json
	;;

savedefconfig)
	efx_require_configured
	[ -n "$PKG" ] || efx_die $EFX_EX_USAGE "savedefconfig does not apply to $COMPONENT"
	efx_lock_acquire "$COMPONENT savedefconfig"
	trap 'efx_lock_release' EXIT

	case "$PKG" in
	linux) efx_run_step kernel savedefconfig -- br_make linux-update-defconfig ;;
	uboot) efx_run_step uboot  savedefconfig -- br_make uboot-update-defconfig ;;
	esac
	;;

config)
	# Not menuconfig — just tell the caller which files actually drive it.
	efx_require_configured
	case "$PKG" in
	linux) show_config_sources BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES ;;
	uboot) show_config_sources BR2_TARGET_UBOOT_CONFIG_FRAGMENT_FILES ;;
	*)     efx_die $EFX_EX_USAGE "no configuration fragments for $COMPONENT" ;;
	esac
	echo
	efx_info "for the interactive editor, run this in a terminal:"
	echo "    make -C $EFX_BUILDROOT_DIR O=$EFX_BUILD_DIR BR2_EXTERNAL=$EFX_REPO_DIR ${PKG}-menuconfig"
	;;

status)
	exec "$EFX_DIR/scripts/efx-status.sh" --component "$COMPONENT"
	;;

*)
	efx_die $EFX_EX_USAGE "unknown verb: $VERB"
	;;
esac
