#!/bin/bash
# Shared helpers for the efx build scripts.
#
# Sourced by tools/efx/efx and every script under tools/efx/scripts.
# Expects EFX_DIR (tools/efx) and EFX_REPO_DIR (repo root) to be set by the caller.

[ -n "${_EFX_COMMON_SH:-}" ] && return 0
_EFX_COMMON_SH=1

set -o pipefail

EFX_LOG_DIR="$EFX_DIR/logs"
EFX_STATE_DIR="$EFX_DIR/state"
EFX_LOCK_FILE="$EFX_STATE_DIR/build.lock"
EFX_JOBS_FILE="$EFX_STATE_DIR/jobs.jsonl"

mkdir -p "$EFX_LOG_DIR" "$EFX_STATE_DIR"

# Exit codes with meaning for the GUI.
EFX_EX_USAGE=2
EFX_EX_CONFIG=3
EFX_EX_BUSY=4
EFX_EX_PREFLIGHT=5

# ---------------------------------------------------------------- logging ---

if [ -t 1 ] && [ -z "${EFX_NO_COLOR:-}" ]; then
	_C_RED=$'\033[0;31m'; _C_GRN=$'\033[0;32m'; _C_YEL=$'\033[0;33m'
	_C_BLU=$'\033[0;34m'; _C_BLD=$'\033[1m';    _C_OFF=$'\033[0m'
else
	_C_RED=''; _C_GRN=''; _C_YEL=''; _C_BLU=''; _C_BLD=''; _C_OFF=''
fi

efx_title() { printf '\n%s==> %s%s\n' "$_C_BLD$_C_BLU" "$*" "$_C_OFF"; }
efx_info()  { printf '%sINFO%s  %s\n' "$_C_GRN" "$_C_OFF" "$*"; }
efx_warn()  { printf '%sWARN%s  %s\n' "$_C_YEL" "$_C_OFF" "$*" >&2; }
efx_err()   { printf '%sERROR%s %s\n' "$_C_RED" "$_C_OFF" "$*" >&2; }
efx_ok()    { printf '%s  ok%s  %s\n' "$_C_GRN" "$_C_OFF" "$*"; }

efx_die()
{
	local rc=$1; shift
	efx_err "$*"
	exit "$rc"
}

# ------------------------------------------------------------------- JSON ---

# Quote $1 as a JSON string.
efx_json_str()
{
	local s=${1-}
	s=${s//\\/\\\\}
	s=${s//\"/\\\"}
	s=${s//$'\n'/\\n}
	s=${s//$'\r'/\\r}
	s=${s//$'\t'/\\t}
	printf '"%s"' "$s"
}

# ------------------------------------------------------------------- misc ---

efx_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }
efx_size()  { stat -c %s "$1" 2>/dev/null || echo 0; }

# Print the filesystem type of the given path.
efx_fstype() { stat -f -c %T "$1" 2>/dev/null || echo unknown; }

# Free space in GiB for the filesystem holding $1.
efx_free_gib()
{
	local avail
	avail=$(df -PB1 "$1" 2>/dev/null | awk 'NR==2 {print $4}')
	echo $(( ${avail:-0} / 1024 / 1024 / 1024 ))
}

# efx_soc_define <soc.h> <SYMBOL> — print the value of a #define.
#
# The Efinity project is authored on Windows and its soc.h has CRLF endings, so
# a naive awk yields "16384\r" — which fails every numeric test and every string
# comparison against "1". Stripping CR here is what keeps that from turning into
# silently wrong build settings. (init.sh has this bug: its RVC detection does
# [[ $ext_c == 1 ]] against a CR-terminated value and always loses, which is why
# efx normalises soc.h to LF before handing it over.)
efx_soc_define()
{
	awk -v k="$2" '
		{ sub(/\r$/, "") }
		$1 == "#define" && $2 == k { print $3; exit }
	' "$1" 2>/dev/null
}

# The FSBL's bootloaderConfig.h: FSBL_CONFIG (relative to tools/efx), or the
# stock header when it is empty. Its flash offsets and copy sizes are what the
# image and flash checks measure against.
efx_fsbl_config()
{
	case "${FSBL_CONFIG:-}" in
	'') echo "$EFX_REPO_DIR/boards/efinix/common/bootloaderConfig.h" ;;
	/*) echo "$FSBL_CONFIG" ;;
	*)  echo "$EFX_DIR/$FSBL_CONFIG" ;;
	esac
}

# efx_efinity <command...> — run an Efinity tool in a clean environment.
#
# Efinity ships its own Python. An activated virtualenv, or a PYTHONPATH from a
# sourced ROS setup, leaks into it and kills it at start-up ("Fatal Python
# error: init_fs_encoding"), so nothing from the calling shell is passed on
# except HOME and EFINITY_HOME's own setup.sh.
efx_efinity()
{
	[ -n "${EFINITY_HOME:-}" ] && [ -f "$EFINITY_HOME/bin/setup.sh" ] \
		|| efx_die $EFX_EX_CONFIG "Efinity not found at '${EFINITY_HOME:-}' — set EFINITY_HOME in efx.conf"
	local cmd q
	cmd="source $(printf '%q' "$EFINITY_HOME/bin/setup.sh") >/dev/null 2>&1 && cd $(printf '%q' "$PWD") &&"
	for q in "$@"; do cmd+=" $(printf '%q' "$q")"; done
	env -i HOME="$HOME" PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 TERM="${TERM:-dumb}" \
		bash -c "$cmd"
}

# --------------------------------------------------------------- the lock ---
#
# One build at a time, repo-wide. The GUI enforces the same rule but the lock is
# what actually makes it true: a CLI build and a GUI build must not collide.

efx_lock_acquire()
{
	local what=$1

	exec 9>"$EFX_LOCK_FILE"
	if ! flock -n 9; then
		local holder
		holder=$(cat "$EFX_STATE_DIR/lock-holder" 2>/dev/null || echo 'another job')
		efx_err "busy: $holder is running. Wait for it or run 'efx cancel'."
		exit $EFX_EX_BUSY
	fi
	printf '%s (pid %s, since %s)\n' "$what" "$$" "$(date -Is)" > "$EFX_STATE_DIR/lock-holder"
	printf '%s\n' "$$" > "$EFX_STATE_DIR/lock-pid"
}

efx_lock_release()
{
	rm -f "$EFX_STATE_DIR/lock-holder" "$EFX_STATE_DIR/lock-pid"
	flock -u 9 2>/dev/null || true
	exec 9>&- 2>/dev/null || true
}

# ------------------------------------------------------------ step runner ---
#
# Runs a command with its output on the terminal and in a timestamped log, then
# records the outcome so `efx status` and the GUI can report it.

efx_record_state()
{
	local component=$1 state=$2 action=$3 rc=$4 log=$5

	printf '{"component":%s,"state":%s,"action":%s,"rc":%s,"log":%s,"time":%s}\n' \
		"$(efx_json_str "$component")" \
		"$(efx_json_str "$state")" \
		"$(efx_json_str "$action")" \
		"$rc" \
		"$(efx_json_str "$log")" \
		"$(efx_json_str "$(date -Is)")" \
		> "$EFX_STATE_DIR/last-$component.json"

	cat "$EFX_STATE_DIR/last-$component.json" >> "$EFX_JOBS_FILE"
}

# efx_run_step <component> <action> -- <command...>
efx_run_step()
{
	local component=$1 action=$2 rc log
	shift 2
	[ "${1:-}" = '--' ] && shift

	log="$EFX_LOG_DIR/${component}-${action}-$(date +%Y%m%d-%H%M%S).log"
	ln -sf "$(basename "$log")" "$EFX_LOG_DIR/${component}-latest.log"

	efx_info "log: $log"
	{
		printf '### efx %s %s\n### %s\n### cwd: %s\n### cmd: %s\n\n' \
			"$component" "$action" "$(date -Is)" "$PWD" "$*"
	} > "$log"

	"$@" 2>&1 | tee -a "$log"
	rc=${PIPESTATUS[0]}

	printf '\n### exit: %s\n' "$rc" >> "$log"

	if [ "$rc" -eq 0 ]; then
		efx_record_state "$component" ok "$action" "$rc" "$log"
	elif [ "$rc" -ge 130 ]; then
		# Interrupted mid-build: the package directory is now untrustworthy.
		efx_record_state "$component" cancelled "$action" "$rc" "$log"
		efx_warn "$component was interrupted — run 'efx $component clean' before building again"
	else
		efx_record_state "$component" failed "$action" "$rc" "$log"
	fi

	return "$rc"
}

# ---------------------------------------------------------------- guards ---

# Refuse to build a component that was left in an unknown state by a cancel.
efx_require_clean_state()
{
	local component=$1 state

	state=$(efx_state_of "$component")
	if [ "$state" = cancelled ]; then
		efx_die $EFX_EX_CONFIG \
			"$component was cancelled mid-build and may be inconsistent. Run 'efx $component clean' first (or 'efx $component rebuild --force')."
	fi
}

efx_state_of()
{
	local f="$EFX_STATE_DIR/last-$1.json"
	[ -f "$f" ] || { echo unknown; return; }
	sed -n 's/.*"state":"\([^"]*\)".*/\1/p' "$f"
}

efx_require_configured()
{
	[ -f "$EFX_BUILD_DIR/.config" ] || efx_die $EFX_EX_CONFIG \
		"not configured yet — run 'efx config configure' first (no $EFX_BUILD_DIR/.config)"
}

# --------------------------------------------------------------- preflight ---

_efx_pf_rc=0
_efx_pf_check()
{
	local label=$1 ok=$2 detail=$3
	if [ "$ok" = 1 ]; then
		efx_ok "$label${detail:+ — $detail}"
	else
		printf '%sFAIL%s  %s%s\n' "$_C_RED" "$_C_OFF" "$label" "${detail:+ — $detail}"
		_efx_pf_rc=1
	fi
}

_efx_pf_warn()
{
	printf '%sWARN%s  %s%s\n' "$_C_YEL" "$_C_OFF" "$1" "${2:+ — $2}"
}

efx_preflight()
{
	local tool free fs

	_efx_pf_rc=0

	efx_title "Host tools"
	for tool in git make jq python3 flock unzip rsync cpio bc wget file; do
		if command -v "$tool" >/dev/null 2>&1; then
			_efx_pf_check "$tool" 1 ''
		else
			_efx_pf_check "$tool" 0 'not on PATH'
		fi
	done
	command -v mkimage >/dev/null 2>&1 \
		&& _efx_pf_check mkimage 1 "$(mkimage -V 2>&1 | head -1)" \
		|| _efx_pf_warn mkimage 'not found (Buildroot builds its own host-uboot-tools)'

	# Host development headers. Buildroot builds almost everything itself, but a
	# few packages compile host tools against system headers — U-Boot's
	# mkeficapsule needs GnuTLS, and it fails well into the build rather than at
	# configure time. Catching it here saves that round trip.
	efx_title "Host development headers"
	local -a missing_pkgs=()
	_efx_pf_header()
	{
		local header=$1 pkg=$2 needed_by=$3
		if echo "#include <$header>" | gcc -E - >/dev/null 2>&1; then
			_efx_pf_check "$header" 1 ''
		else
			_efx_pf_check "$header" 0 "needed by $needed_by — install $pkg"
			missing_pkgs+=("$pkg")
		fi
	}
	_efx_pf_header ncurses.h libncurses-dev 'menuconfig'

	# genimage shells out to mcopy to fill the FAT boot partition. Without it the
	# Buildroot build still exits 0, just with no sdcard.img — so flag it here.
	if command -v mcopy >/dev/null 2>&1; then
		_efx_pf_check mcopy 1 "$(mcopy --version 2>&1 | head -1)"
	elif [ "$ROOTFS_MODE" = sdcard ]; then
		_efx_pf_check mcopy 0 'required to build sdcard.img — see docs/known_issues.md (build mtools 4.0.44 from source)'
	else
		_efx_pf_warn mcopy "absent — only needed for ROOTFS_MODE=sdcard (currently $ROOTFS_MODE)"
	fi

	# GnuTLS is only needed for U-Boot's mkeficapsule, which overlays/uboot_ti375_oob.cfg
	# switches off (this board has no EFI). Report it, but do not fail on it.
	if echo '#include <gnutls/gnutls.h>' | gcc -E - >/dev/null 2>&1; then
		_efx_pf_check 'gnutls/gnutls.h' 1 ''
	else
		_efx_pf_warn 'gnutls/gnutls.h' 'absent — fine, CONFIG_TOOLS_MKEFICAPSULE is disabled. Install libgnutls28-dev only if you re-enable it.'
	fi

	if [ ${#missing_pkgs[@]} -gt 0 ]; then
		printf '        install with: sudo apt-get install -y %s\n' "${missing_pkgs[*]}"
	fi

	efx_title "Configuration"
	if [ -f "$EFX_DIR/efx.conf" ]; then
		_efx_pf_check 'efx.conf' 1 "$EFX_DIR/efx.conf"
	else
		_efx_pf_check 'efx.conf' 0 "missing — run 'efx config detect --write'"
	fi

	local problems
	if problems=$(efx_conf_validate 2>&1); then
		_efx_pf_check 'schema validation' 1 ''
	else
		_efx_pf_check 'schema validation' 0 ''
		printf '        %s\n' "$problems"
	fi

	efx_title "Toolchain"
	if [ -x "$RISCV_BIN_DIR/${RISCV_PREFIX}gcc" ]; then
		_efx_pf_check 'bare-metal gcc' 1 "$("$RISCV_BIN_DIR/${RISCV_PREFIX}gcc" --version | head -1)"
	else
		_efx_pf_check 'bare-metal gcc' 0 "$RISCV_BIN_DIR/${RISCV_PREFIX}gcc"
	fi

	efx_title "Efinity"
	if [ -x "$EFINITY_HOME/bin/efx_run" ]; then
		_efx_pf_check 'efx_run' 1 "$(sed -n 's/^base_version *= *//p' "$EFINITY_HOME/MANIFEST" 2>/dev/null | head -1)"
		[ -x "$EFINITY_HOME/bin/efx_bram_update" ] \
			&& _efx_pf_check 'efx_bram_update' 1 '' \
			|| _efx_pf_check 'efx_bram_update' 0 'missing'
		[ -x "$EFINITY_HOME/bin/efx_pgm" ] \
			&& _efx_pf_check 'efx_pgm' 1 '' \
			|| _efx_pf_check 'efx_pgm' 0 'missing'
	else
		_efx_pf_warn 'Efinity' "not found at $EFINITY_HOME — FPGA steps unavailable, software build unaffected"
	fi

	efx_title "Project"
	if [ -f "$EFX_SOC_H" ]; then
		_efx_pf_check "soc.h ($SOC_VARIANT)" 1 "$EFX_SOC_H"
	else
		_efx_pf_check "soc.h ($SOC_VARIANT)" 0 "$EFX_SOC_H"
	fi

	if [ -d "$EFX_PROJECT_DIR" ]; then
		fs=$(efx_fstype "$EFX_PROJECT_DIR")
		case "$fs" in
		ext2/ext3|xfs|btrfs|tmpfs) _efx_pf_check 'project filesystem' 1 "$fs" ;;
		*) _efx_pf_warn 'project filesystem' "$fs — no POSIX permissions/symlinks; efx keeps locks, logs and state on the repo filesystem" ;;
		esac
	fi

	efx_title "Resources"
	free=$(efx_free_gib "$EFX_REPO_DIR")
	if [ "$free" -ge 30 ]; then
		_efx_pf_check 'free disk' 1 "${free} GiB"
	else
		_efx_pf_check 'free disk' 0 "${free} GiB — a full Buildroot build needs ~30 GiB (set EFX_DL_DIR / EFX_CCACHE_DIR to relocate caches)"
	fi
	efx_ok "parallel jobs — $EFX_JOBS"

	if [ -n "$EFX_DL_DIR$EFX_CCACHE_DIR" ]; then
		efx_info "download cache: ${EFX_DL_DIR:-<buildroot default>}"
		efx_info "ccache dir:     ${EFX_CCACHE_DIR:-<buildroot default>}"
	else
		_efx_pf_warn 'caches' 'Buildroot will use $HOME/.buildroot-* — set EFX_DL_DIR / EFX_CCACHE_DIR to keep them off the home partition'
	fi

	echo
	if [ $_efx_pf_rc -eq 0 ]; then
		efx_info "preflight passed"
	else
		efx_err "preflight found problems (see FAIL lines above)"
	fi
	return $_efx_pf_rc
}
