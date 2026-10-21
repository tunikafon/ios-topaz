#!/bin/bash
# Flash the iOS 16 root into userdata and boot the topaz shim.
#
#   flash.sh [--yes]
#
# Two commands do the work:
#   fastboot -S 512M flash userdata ios16-root.simg
#   fastboot boot shim/out/shim-boot.img
#
# (run from the repository root /home/tunikafon/Projects/ios-topaz)
#
# !! userdata is overwritten: Android (HyperOS) and everything in it is gone.
# !! boot, vendor_boot, firmware, persist and the other partitions are never
#    written, so the phone can still be brought back with RECOVERY.md.
set -euo pipefail

REPO=/home/tunikafon/Projects/ios-topaz
ROOT_IMG=${ROOT_IMG:-$REPO/ios16-root.simg}
BOOT_IMG=${BOOT_IMG:-$REPO/shim/out/shim-boot.img}
BACKUP_DIR=${BACKUP_DIR:-$REPO/work/gpt-backup}
ASSUME_YES=0
[ "${1:-}" = "--yes" ] && ASSUME_YES=1

for f in "$ROOT_IMG" "$BOOT_IMG"; do
	[[ -f $f ]] || { echo "missing: $f" >&2; exit 1; }
done

echo "== fastboot devices =="
fastboot devices
fastboot getvar current-slot 2>&1 | head -1
fastboot getvar unlocked 2>&1 | head -1

if [ $ASSUME_YES != 1 ]; then
	echo
	echo "The following will ERASE userdata (Android and all its data):"
	echo "  fastboot -S 512M flash userdata $ROOT_IMG"
	echo "  fastboot boot $BOOT_IMG"
	read -r -p "Type 'yes' to continue: " a
	[ "$a" = "yes" ] || { echo "aborted"; exit 1; }
fi

# GPT heads of LUN0 (userdata, esp, win) before anything is written: the iOS
# UFS driver has damaged the LUN0 GPT before (RECOVERY.md, 2026-10-19).
if fastboot fetch partition:0 "$BACKUP_DIR/lun0.head.bin" 2>/dev/null; then
	echo "GPT head of LUN0 saved to $BACKUP_DIR/lun0.head.bin"
elif fastboot fetch partition:4 "$BACKUP_DIR/lun4.head.bin" 2>/dev/null; then
	echo "GPT head of LUN4 saved to $BACKUP_DIR/lun4.head.bin"
else
	echo "note: this bootloader does not support 'fastboot fetch';"
	echo "      back the GPT up with TWRP: dd if=/dev/block/by-name/userdata bs=1M count=1"
fi

echo "== flashing the iOS root into userdata (this erases Android) =="
fastboot -S 512M flash userdata "$ROOT_IMG"

echo "== booting the shim =="
fastboot boot "$BOOT_IMG"

cat <<'EOF'

The shim screen (red) shows MMFR0, the Gold hand-off and SPEED silver=... gold=...
for 8 seconds, then XNU starts. The first boot waits a while on the Apple logo
(SpringBoard builds the LaunchServices database); the lock screen follows after
about 3 minutes. To get back to fastboot: hold Power + Volume down.
EOF
