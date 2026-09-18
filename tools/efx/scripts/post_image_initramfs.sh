#!/bin/bash
# Buildroot post-image hook, added by `efx config` when ROOTFS_MODE=initramfs.
#
# boards/efinix/common/post_build.sh makes Image and uImage from vmlinux, but
# it runs as a post-build hook, during target-finalize. With the rootfs built
# into the kernel, Buildroot relinks vmlinux with the initramfs only after
# that, so the Image it left behind is a kernel with no root filesystem, which
# panics at boot. Post-image hooks run after the relink; rebuild both images
# here from the final vmlinux, and refuse to succeed if it has no initramfs.
#
# $1 = BINARIES_DIR (Buildroot passes it); HOST_DIR comes from the environment.

set -e

IMAGES=${1:-$BINARIES_DIR}
VMLINUX="$IMAGES/vmlinux"
LINUX_ADDRESS=0x00400000        # same load address as post_build.sh

[ -f "$VMLINUX" ] || { echo "post_image_initramfs: no $VMLINUX" >&2; exit 1; }

case "$(file -b "$VMLINUX")" in
    *64-bit*) CROSS=riscv64-buildroot-linux-gnu- ;;
    *)        CROSS=riscv32-buildroot-linux-gnu- ;;
esac
OBJCOPY="$HOST_DIR/bin/${CROSS}objcopy"
NM="$HOST_DIR/bin/${CROSS}nm"

# The linker script folds .init.ramfs into .init.data, so there is no section
# to measure; usr/initramfs_data.S brackets the archive with __irf_start and
# __irf_end instead. A kernel without an initramfs has a stub of a few bytes.
irf_start=$("$NM" "$VMLINUX" | awk '$3 == "__irf_start" { print $1 }')
irf_end=$("$NM" "$VMLINUX" | awk '$3 == "__irf_end" { print $1 }')
ramfs=''
[ -n "$irf_start" ] && [ -n "$irf_end" ] && ramfs=$(( 0x$irf_end - 0x$irf_start ))
if [ -z "$ramfs" ] || [ "$ramfs" -le 512 ]; then
    echo "post_image_initramfs: $VMLINUX carries no initramfs (__irf_start..__irf_end is ${ramfs:-missing})" >&2
    exit 1
fi

"$OBJCOPY" -O binary "$VMLINUX" "$IMAGES/Image"
"$HOST_DIR/bin/mkimage" -A riscv -O linux -T kernel -C none \
    -a $LINUX_ADDRESS -e $LINUX_ADDRESS -n Linux \
    -d "$IMAGES/Image" "$IMAGES/uImage" > /dev/null

echo "post_image_initramfs: Image $(stat -c %s "$IMAGES/Image") bytes, initramfs $ramfs bytes"
