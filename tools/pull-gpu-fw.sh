#!/bin/bash
# Pull the Adreno 610 firmware out of the phone's vendor partition (inside
# super) and extract the three files TopazAdreno needs:
#   a610_zap.mdt  a610_zap.b02  a630_sqe.fw
# The phone must be in TWRP (fastboot boot work/twrp-topaz.img), adb root.
# The vendor image is EROFS; extraction happens on this machine.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=work/gpu-fw
mkdir -p "$OUT"

[ -n "$(adb devices | awk 'NR==2 && $2=="device"')" ] || { echo "no adb device (boot TWRP first)" >&2; exit 1; }

echo "=== vendor_a via dm-linear in TWRP"
# TWRP knows dynamic partitions; ask it to map vendor, else dd the whole super.
if adb shell "test -b /dev/block/mapper/vendor_a" 2>/dev/null; then
	BLOCK=/dev/block/mapper/vendor_a
else
	BLOCK=/dev/block/by-name/super
fi
echo "pulling $BLOCK"
adb pull "$BLOCK" "$OUT/vendor_a.raw"

echo "=== extracting (EROFS)"
if [ "$BLOCK" = /dev/block/by-name/super ]; then
	pip install --quiet erofs-utils 2>/dev/null || true
	command -v lpunpack >/dev/null || { echo "need lpunpack for super" >&2; exit 1; }
	lpunpack --partition=vendor_a "$OUT/vendor_a.raw" "$OUT/vendor_a.img"
	IMG="$OUT/vendor_a.img"
else
	IMG="$OUT/vendor_a.raw"
fi
mkdir -p "$OUT/extracted"
fsck.erofs --extract="$OUT/extracted" "$IMG" 2>/dev/null || python3 - "$IMG" "$OUT/extracted" <<'EOF'
# erofs fallback: use dump.erofs/fuse. If nothing works, say so clearly.
import sys
sys.exit("EROFS extraction failed: install erofs-utils (fsck.erofs) or use TWRP's /vendor mount")
EOF

for f in a610_zap.mdt a610_zap.b02 a630_sqe.fw; do
	SRC=$(find "$OUT/extracted" -name "$f" | head -1)
	[ -n "$SRC" ] || { echo "MISSING $f in vendor" >&2; continue; }
	cp "$SRC" "$OUT/$f"
done
ls -l "$OUT"/a610_* "$OUT"/a630_* 2>/dev/null || true
echo "done: work/gpu-fw/ — build the boot image with GPUFW=\"$OUT/a610_zap.mdt $OUT/a610_zap.b02 $OUT/a630_sqe.fw\""
