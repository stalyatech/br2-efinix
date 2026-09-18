#!/bin/bash
# efx configuration loading, validation and persistence.
#
# Sourced by lib/common.sh — do not execute directly.
#
# The configuration file is parsed line by line rather than sourced: the web GUI
# writes it, so it must never be able to inject shell code.

[ -n "${_EFX_CONF_SH:-}" ] && return 0
_EFX_CONF_SH=1

declare -A EFX_KEY_TYPE EFX_KEY_DEFAULT EFX_KEY_GROUP EFX_KEY_DESC
declare -a EFX_KEY_NAMES=()

# Populate the EFX_KEY_* tables from efx.keys.
efx_keys_parse()
{
	local line name type def group desc

	[ ${#EFX_KEY_NAMES[@]} -gt 0 ] && return 0

	[ -f "$EFX_DIR/efx.keys" ] || {
		echo "efx: missing schema file $EFX_DIR/efx.keys" >&2
		return 1
	}

	while IFS= read -r line; do
		case "$line" in
		''|'#'*) continue ;;
		esac

		IFS='|' read -r name type def group desc <<<"$line"
		[ -n "$name" ] || continue

		EFX_KEY_NAMES+=("$name")
		EFX_KEY_TYPE[$name]=$type
		EFX_KEY_DEFAULT[$name]=$def
		EFX_KEY_GROUP[$name]=$group
		EFX_KEY_DESC[$name]=$desc
	done < "$EFX_DIR/efx.keys"
}

# Apply schema defaults to any key that is not already set in the environment.
efx_conf_defaults()
{
	local name

	for name in "${EFX_KEY_NAMES[@]}"; do
		[ -n "${!name:-}" ] || printf -v "$name" '%s' "${EFX_KEY_DEFAULT[$name]}"
		export "${name?}"
	done
}

# Read KEY=VALUE pairs from $1 (default: efx.conf) into the environment.
# Unknown keys are reported but not fatal, so a newer efx.conf stays readable.
efx_conf_load()
{
	local file=${1:-$EFX_DIR/efx.conf}
	local line name value

	efx_keys_parse || return 1

	if [ -f "$file" ]; then
		while IFS= read -r line; do
			case "$line" in
			''|'#'*) continue ;;
			esac

			name=${line%%=*}
			value=${line#*=}
			name=${name//[[:space:]]/}
			[ -n "$name" ] || continue

			# strip one layer of surrounding quotes
			value=${value#"${value%%[![:space:]]*}"}
			case "$value" in
			\"*\") value=${value:1:${#value}-2} ;;
			\'*\') value=${value:1:${#value}-2} ;;
			esac

			if [ -z "${EFX_KEY_TYPE[$name]+x}" ]; then
				echo "efx: warning: unknown key '$name' in $file (ignored)" >&2
				continue
			fi

			printf -v "$name" '%s' "$value"
			export "${name?}"
		done < "$file"
	fi

	efx_conf_defaults
	efx_conf_derive
}

# Recompute everything that follows from the configured keys. Called at the end
# of efx_conf_load and again after efx_conf_detect, so detection results are
# reflected in the derived paths.
efx_conf_derive()
{
	# JOBS stays as configured (possibly empty) so efx_conf_write does not pin
	# it to this machine's core count; EFX_JOBS is what builds actually use.
	EFX_JOBS=${JOBS:-$(nproc)}
	export EFX_JOBS

	# init.sh always puts the workspace next to the repo; resolve the ".." so
	# paths shown to the user and stored in state are canonical.
	EFX_WORKSPACE_DIR=$(realpath -m "$EFX_REPO_DIR/../$WORKSPACE")
	EFX_BUILDROOT_DIR="$EFX_WORKSPACE_DIR/buildroot"
	EFX_BUILD_DIR="$EFX_WORKSPACE_DIR/build"
	EFX_IMAGES_DIR="$EFX_BUILD_DIR/images"
	export EFX_WORKSPACE_DIR EFX_BUILDROOT_DIR EFX_BUILD_DIR EFX_IMAGES_DIR

	case "$SOC_VARIANT" in
	hard) EFX_BSP_NAME=efx_hard_soc ;;
	fcu)  EFX_BSP_NAME=EfxSapphireFCU ;;
	esac
	EFX_SOC_H="$EFX_PROJECT_DIR/embedded_sw/$EFX_BSP_NAME/bsp/efinix/EfxSapphireSoc/include/soc.h"
	export EFX_BSP_NAME EFX_SOC_H

	case "$FSBL_HOST" in
	hard) EFX_FSBL_BSP_NAME=efx_hard_soc ;;
	fcu)  EFX_FSBL_BSP_NAME=EfxSapphireFCU ;;
	esac
	export EFX_FSBL_BSP_NAME

	# Where the FSBL build lands in the Efinity project. bootloader.hex there
	# is what OCR_FILE_PATH in <project>.peri.xml points at.
	EFX_FSBL_DIR="$EFX_PROJECT_DIR/sw/boot"
	export EFX_FSBL_DIR
}

# Validate the loaded configuration against the schema.
# Returns non-zero and prints one line per problem.
efx_conf_validate()
{
	local name type value rc=0 allowed

	for name in "${EFX_KEY_NAMES[@]}"; do
		type=${EFX_KEY_TYPE[$name]}
		value=${!name:-}

		# Empty is always allowed; each consumer decides whether it needs the key.
		[ -n "$value" ] || continue

		case "$type" in
		dir)
			[ -d "$value" ] || { echo "$name: not a directory: $value"; rc=1; }
			;;
		file)
			[ -f "$value" ] || { echo "$name: not a file: $value"; rc=1; }
			;;
		outdir)
			[ -e "$value" ] && [ ! -d "$value" ] && { echo "$name: exists but is not a directory: $value"; rc=1; }
			;;
		int)
			[[ $value =~ ^[0-9]+$ ]] || { echo "$name: not an integer: $value"; rc=1; }
			;;
		bool)
			case "$value" in yes|no) ;; *) echo "$name: expected yes or no: $value"; rc=1 ;; esac
			;;
		enum:*)
			allowed=${type#enum:}
			if [[ ",$allowed," != *",$value,"* ]]; then
				echo "$name: expected one of $allowed, got: $value"
				rc=1
			fi
			;;
		esac
	done

	# Cross-key checks that the schema cannot express.
	if [ -n "$EFX_PROJECT_DIR" ] && [ ! -f "$EFX_SOC_H" ]; then
		echo "EFX_PROJECT_DIR/SOC_VARIANT: soc.h not found at $EFX_SOC_H"
		rc=1
	fi

	if [ -n "$RISCV_BIN_DIR" ] && [ ! -x "$RISCV_BIN_DIR/${RISCV_PREFIX}gcc" ]; then
		echo "RISCV_BIN_DIR/RISCV_PREFIX: no executable at $RISCV_BIN_DIR/${RISCV_PREFIX}gcc"
		rc=1
	fi

	if [ -n "$SOCMAP_OVERLAY" ] && [ ! -f "$EFX_DIR/$SOCMAP_OVERLAY" ]; then
		echo "SOCMAP_OVERLAY: not found: $EFX_DIR/$SOCMAP_OVERLAY"
		rc=1
	fi

	return $rc
}

# Best-effort autodetection for keys that are still empty.
efx_conf_detect()
{
	local candidate

	if [ -z "$EFX_PROJECT_DIR" ]; then
		for candidate in \
			/media/tmk/windata/Projects/fpga/efinix/project/fpga/ti375_oob \
			"$HOME/ti375_oob"
		do
			[ -f "$candidate/${FPGA_PROJECT}.xml" ] && { EFX_PROJECT_DIR=$candidate; break; }
		done
	fi

	if [ -z "$EFINITY_HOME" ] || [ ! -d "$EFINITY_HOME" ]; then
		for candidate in /media/tmk/uniwork/tools/efx/efinity/*/; do
			[ -x "${candidate}bin/efx_run" ] && EFINITY_HOME=${candidate%/}
		done
	fi

	if [ -z "$RISCV_BIN_DIR" ] || [ ! -x "$RISCV_BIN_DIR/${RISCV_PREFIX}gcc" ]; then
		for candidate in \
			/media/tmk/uniwork/tools/riscv/xpack-riscv-none-elf-gcc/bin \
			/opt/xpack-riscv-none-elf-gcc/bin
		do
			[ -x "$candidate/${RISCV_PREFIX}gcc" ] && { RISCV_BIN_DIR=$candidate; break; }
		done
	fi

	export EFX_PROJECT_DIR EFINITY_HOME RISCV_BIN_DIR
	efx_conf_derive
}

# Write the current configuration to $1 (default: efx.conf), schema-ordered and
# commented. Rewrites the file atomically.
efx_conf_write()
{
	local file=${1:-$EFX_DIR/efx.conf}
	local tmp name group last_group=''

	tmp=$(mktemp "${file}.XXXXXX") || return 1

	{
		echo "# efx configuration — generated $(date -Is)"
		echo "# Schema and descriptions: tools/efx/efx.keys"
	} > "$tmp"

	for name in "${EFX_KEY_NAMES[@]}"; do
		group=${EFX_KEY_GROUP[$name]}
		if [ "$group" != "$last_group" ]; then
			printf '\n# ---- %s %s\n' "$group" "$(printf '%.0s-' $(seq 1 $((60 - ${#group}))))" >> "$tmp"
			last_group=$group
		fi
		printf '# %s\n%s=%s\n' "${EFX_KEY_DESC[$name]}" "$name" "${!name:-}" >> "$tmp"
	done

	mv -f "$tmp" "$file"
}

# Emit the schema plus current values as JSON for the web GUI.
efx_conf_json()
{
	local name first=1

	printf '{"keys":['
	for name in "${EFX_KEY_NAMES[@]}"; do
		[ $first -eq 1 ] || printf ','
		first=0
		printf '{"name":%s,"type":%s,"group":%s,"description":%s,"default":%s,"value":%s}' \
			"$(efx_json_str "$name")" \
			"$(efx_json_str "${EFX_KEY_TYPE[$name]}")" \
			"$(efx_json_str "${EFX_KEY_GROUP[$name]}")" \
			"$(efx_json_str "${EFX_KEY_DESC[$name]}")" \
			"$(efx_json_str "${EFX_KEY_DEFAULT[$name]}")" \
			"$(efx_json_str "${!name:-}")"
	done
	printf ']}'
}
