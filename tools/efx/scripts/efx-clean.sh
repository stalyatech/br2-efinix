#!/bin/bash
# efx clean — the destructive end of the cleaning spectrum.
#
# Per-component cleaning lives with the component (`efx kernel clean`); this
# script handles the levels that cut across components.

set -u

: "${EFX_DIR:?must be run through tools/efx/efx}"
. "$EFX_DIR/lib/common.sh"
. "$EFX_DIR/lib/conf.sh"
efx_conf_load || exit $EFX_EX_CONFIG

LEVEL=${1:-}
[ $# -gt 0 ] && shift

# The level is positional, so a lone --help arrives as $LEVEL, not as an option.
case "$LEVEL" in -h|--help) set -- --help ;; esac

YES=0
while [ $# -gt 0 ]; do
	case "$1" in
	-y|--yes) YES=1 ;;
	-h|--help)
		cat <<-EOF
		Usage: efx clean <level> [-y]

		Levels:
		  images      Remove generated images only (keeps everything built)
		  build       Buildroot 'make clean' — drops build/, host/, target/, staging/
		              and images/, keeps .config and the download cache
		  logs        Remove efx logs and recorded job state
		  workspace   Delete $EFX_WORKSPACE_DIR entirely (Buildroot checkout included)
		  repo-reset  Restore the repo files that the configuration step rewrote

		For a single component use its own clean, which is far cheaper:
		  efx kernel clean      (linux-dirclean)
		EOF
		exit 0
		;;
	*) efx_die $EFX_EX_USAGE "unknown option: $1" ;;
	esac
	shift
done

confirm()
{
	local prompt=$1
	[ $YES -eq 1 ] && return 0
	if [ ! -t 0 ]; then
		efx_die $EFX_EX_USAGE "$prompt — pass -y to confirm non-interactively"
	fi
	read -r -p "$prompt [y/N] " reply
	case "$reply" in y|Y|yes|YES) return 0 ;; *) efx_die 1 "aborted" ;; esac
}

case "$LEVEL" in
build)
	efx_require_configured
	efx_warn "Buildroot's 'clean' removes build/, host/, target/, staging/ and images/"
	efx_warn "the toolchain goes with it — the next build takes as long as the first"
	confirm "Run 'make clean' in $EFX_BUILD_DIR?"

	efx_lock_acquire "clean build"
	trap 'efx_lock_release' EXIT
	efx_run_step image clean -- \
		env -C "$EFX_BUILD_DIR" make -C "$EFX_BUILDROOT_DIR" O="$EFX_BUILD_DIR" \
			BR2_EXTERNAL="$EFX_REPO_DIR" clean
	rm -f "$EFX_STATE_DIR"/last-{opensbi,uboot,kernel,image}.json
	;;

images)
	[ -d "$EFX_IMAGES_DIR" ] || efx_die 1 "no images directory: $EFX_IMAGES_DIR"
	confirm "Delete everything under $EFX_IMAGES_DIR?"
	rm -rf "${EFX_IMAGES_DIR:?}"/*
	rm -f "$EFX_STATE_DIR"/last-{opensbi,uboot,kernel,image}.json
	efx_info "images removed"
	;;

logs)
	rm -rf "${EFX_LOG_DIR:?}"/*
	rm -f "$EFX_STATE_DIR"/last-*.json "$EFX_JOBS_FILE"
	efx_info "logs and job history removed"
	;;

workspace)
	[ -d "$EFX_WORKSPACE_DIR" ] || efx_die 1 "no workspace: $EFX_WORKSPACE_DIR"
	efx_warn "this removes the Buildroot checkout, the toolchain and every build artefact"
	efx_warn "target: $EFX_WORKSPACE_DIR ($(du -sh "$EFX_WORKSPACE_DIR" 2>/dev/null | cut -f1))"
	confirm "Delete $EFX_WORKSPACE_DIR?"
	rm -rf "${EFX_WORKSPACE_DIR:?}"
	rm -f "$EFX_STATE_DIR"/last-*.json
	efx_info "workspace removed — run 'efx config configure' to start over"
	;;

repo-reset)
	exec "$EFX_DIR/scripts/efx-config.sh" reset
	;;

''|*)
	efx_die $EFX_EX_USAGE "unknown level: ${LEVEL:-<none>} (images|build|logs|workspace|repo-reset)"
	;;
esac
