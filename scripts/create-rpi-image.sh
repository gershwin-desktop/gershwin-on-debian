#!/bin/bash
set -euo pipefail

OUTPUT_IMAGE=${1:?Usage: $0 <output-image>}
CHROOT_DIR=${CHROOT_DIR:-chroot}

if [ ! -d "$CHROOT_DIR" ]; then
  echo "Error: chroot directory '$CHROOT_DIR' not found." >&2
  exit 1
fi

if [ "$(uname -m)" != "aarch64" ] && [ "$(uname -m)" != "arm64" ]; then
  echo "Error: Raspberry Pi image creation is only supported on arm64/aarch64 builders." >&2
  exit 1
fi

if [ ! -d "$CHROOT_DIR/boot/firmware" ]; then
  echo "Error: missing '$CHROOT_DIR/boot/firmware'. Ensure raspi-firmware is installed in the image." >&2
  exit 1
fi

KERNEL_FILE=$(ls -1 "$CHROOT_DIR"/boot/vmlinuz-* 2>/dev/null | sort -V | tail -n1 || true)
INITRD_FILE=$(ls -1 "$CHROOT_DIR"/boot/initrd.img-* 2>/dev/null | sort -V | tail -n1 || true)

if [ -z "$KERNEL_FILE" ] || [ -z "$INITRD_FILE" ]; then
  echo "Error: could not detect kernel/initramfs in '$CHROOT_DIR/boot'." >&2
  exit 1
fi

BOOT_PARTITION_SIZE_MB=256
ROOTFS_USED_MB=$(du -sBM "$CHROOT_DIR" | awk '{gsub(/M/,"",$1); print $1}')
ROOTFS_SLACK_MB=768
ROOT_PARTITION_SIZE_MB=$((ROOTFS_USED_MB + ROOTFS_SLACK_MB))
TOTAL_SIZE_MB=$((BOOT_PARTITION_SIZE_MB + ROOT_PARTITION_SIZE_MB + 32))

truncate -s "${TOTAL_SIZE_MB}M" "$OUTPUT_IMAGE"

parted -s "$OUTPUT_IMAGE" mklabel gpt
parted -s "$OUTPUT_IMAGE" mkpart firmware fat32 1MiB "$((BOOT_PARTITION_SIZE_MB + 1))MiB"
parted -s "$OUTPUT_IMAGE" mkpart rootfs ext4 "$((BOOT_PARTITION_SIZE_MB + 1))MiB" 100%
parted -s "$OUTPUT_IMAGE" set 1 msftdata on

LOOP_DEVICE=
WORKDIR=$(mktemp -d)
cleanup() {
  set +e
  mountpoint -q "$WORKDIR/boot" && umount "$WORKDIR/boot"
  mountpoint -q "$WORKDIR/root" && umount "$WORKDIR/root"
  [ -n "$LOOP_DEVICE" ] && losetup -d "$LOOP_DEVICE"
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

LOOP_DEVICE=$(losetup --show --find --partscan "$OUTPUT_IMAGE")

mkfs.vfat -F32 -n FIRMWARE "${LOOP_DEVICE}p1"
mkfs.ext4 -F -L rootfs "${LOOP_DEVICE}p2"

mkdir -p "$WORKDIR/root" "$WORKDIR/boot"
mount "${LOOP_DEVICE}p2" "$WORKDIR/root"
mount "${LOOP_DEVICE}p1" "$WORKDIR/boot"

rsync -aHAX --numeric-ids \
  --exclude='/boot/firmware/*' \
  --exclude='/dev/*' \
  --exclude='/proc/*' \
  --exclude='/sys/*' \
  --exclude='/run/*' \
  --exclude='/tmp/*' \
  "$CHROOT_DIR"/ "$WORKDIR/root"/

mkdir -p "$WORKDIR/root/boot/firmware"
rsync -a "$CHROOT_DIR/boot/firmware/" "$WORKDIR/boot/"

KERNEL_BASENAME=$(basename "$KERNEL_FILE")
INITRD_BASENAME=$(basename "$INITRD_FILE")

if [ ! -f "$WORKDIR/boot/$KERNEL_BASENAME" ]; then
  cp "$KERNEL_FILE" "$WORKDIR/boot/$KERNEL_BASENAME"
fi
if [ ! -f "$WORKDIR/boot/$INITRD_BASENAME" ]; then
  cp "$INITRD_FILE" "$WORKDIR/boot/$INITRD_BASENAME"
fi

cat > "$WORKDIR/root/etc/fstab" <<'FSTAB'
LABEL=rootfs / ext4 defaults,noatime 0 1
LABEL=FIRMWARE /boot/firmware vfat defaults 0 2
FSTAB

cat > "$WORKDIR/boot/cmdline.txt" <<'CMDLINE'
console=serial0,115200 console=tty1 root=LABEL=rootfs rootfstype=ext4 fsck.repair=yes rootwait rw quiet splash
CMDLINE

cat > "$WORKDIR/boot/config.txt" <<EOF_CFG
arm_64bit=1
enable_uart=1
kernel=$KERNEL_BASENAME
initramfs $INITRD_BASENAME followkernel
EOF_CFG

sync

echo "Created Raspberry Pi image: $OUTPUT_IMAGE"
