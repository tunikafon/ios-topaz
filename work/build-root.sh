#!/bin/bash
# Build the iOS 16 root for topaz (Redmi Note 12 4G) end to end.
#
#   build-root.sh [OUT_IMG] [SIZE]
#
# Downloads the three disk images of the iPhone X 16.7.16 IPSW one at a time
# (HTTP range requests, so the 6 GB IPSW itself is never downloaded), copies
# them into one HFS+ volume, applies the SWEET bring-up tweaks and writes the
# sparse image fastboot wants.
#
# Disk: the HFS+ image holds ~11 GB of data, the OS image 4.7 GB and the
# SystemOS image 2.7 GB.  Each .dmg is deleted right after its copy, and the
# conversion to the sparse image punches holes into the raw image, so the peak
# usage stays around 11 GB.  The SystemOS image is unpacked into RAM (tmpfs)
# because it is needed twice (unpacked and copied) and the disk is full.
#
# The stages are resumable: a marker in work/.stage-* skips the stages that
# are already done, so a restart does not download the IPSW pieces again.
set -euo pipefail

export PATH="$PATH:$HOME/bin"
REPO=/home/tunikafon/Projects/ios-topaz
WORK=$REPO/work
IPSW_URL="https://updates.cdn-apple.com/2025FallFCS/fullrestores/122-77006/1158E502-D76D-4226-AA06-ED5E30CD1111/iPhone10,3,iPhone10,6_16.7.16_20H392_Restore.ipsw"

OUT=${1:-$WORK/ios16-root.img}
SIZE=${2:-16G}
SPARSE=${OUT%.img}.simg
IPSWDIR=$WORK/ipsw
# The SystemOS cryptex is unpacked into RAM: the disk has no room for the
# unpacked image and its copy at the same time.
SYSDIR=${SYSDIR:-/dev/shm/ios-topaz}
mkdir -p "$IPSWDIR" "$SYSDIR"

cd "$REPO"
log() { echo "=== $* ==="; }

stage_done() { [ -f "$WORK/.stage-$1" ]; }
mark_done() { touch "$WORK/.stage-$1"; }

fetch() { # fetch PATTERN DIR -> prints the local path
	local pattern=$1 dir=$2
	if [ ! -f "$dir/$pattern" ]; then
		log "downloading $pattern into $dir"
		# the progress of the download must not end up in the path
		bash work/fetch-ipsw.sh "$pattern" "$dir" >&2
	fi
	echo "$dir/$pattern"
}

log "manifest"
BM=$IPSWDIR/BuildManifest.plist
if [ ! -f "$BM" ]; then
	bash work/fetch-ipsw.sh BuildManifest.plist "$IPSWDIR"
fi
set -- $(python3 work/ipsw-paths.py "$BM")
OS_DMG_NAME=$1 SYSOS_DMG_NAME=$2 APPOS_DMG_NAME=$3
echo "OS=$OS_DMG_NAME SystemOS=$SYSOS_DMG_NAME AppOS=$APPOS_DMG_NAME"

# 1. the HFS+ volume
if [ ! -f "$OUT" ]; then
	# The volume is gone: everything that was copied into it is gone too.
	rm -f "$WORK"/.stage-*
	log "creating the HFS+ volume ($SIZE)"
	bash work/mkroot-topaz.sh init "$OUT" "$SIZE"
fi

# 2. the OS root
if ! stage_done os; then
	OS_DMG=$(fetch "$OS_DMG_NAME" "$IPSWDIR")
	log "copying the OS root"
	bash work/mkroot-topaz.sh os "$OUT" "$OS_DMG"
	rm -f "$OS_DMG"
	mark_done os
	df -h / | tail -1
fi

# 3. the SystemOS cryptex
if ! stage_done sysos; then
	SYSOS_DMG=$(fetch "$SYSOS_DMG_NAME" "$SYSDIR")
	log "copying the SystemOS cryptex"
	bash work/mkroot-topaz.sh sysos "$OUT" "$SYSOS_DMG"
	rm -f "$SYSOS_DMG" "$SYSDIR/$SYSOS_DMG_NAME.raw"
	mark_done sysos
	df -h / | tail -1
fi

# 4. the AppOS cryptex
if ! stage_done appos; then
	APPOS_DMG=$(fetch "$APPOS_DMG_NAME" "$IPSWDIR")
	log "copying the AppOS cryptex"
	bash work/mkroot-topaz.sh appos "$OUT" "$APPOS_DMG"
	rm -f "$APPOS_DMG"
	mark_done appos
	df -h / | tail -1
fi

# 5. keybag, cryptex hard links, logd directories, fsck
if ! stage_done finish; then
	log "finishing the volume"
	bash work/mkroot-topaz.sh finish "$OUT"
	mark_done finish
fi

# 6. the SWEET bring-up tweaks (launchd, SpringBoard, Setup, ...)
if ! stage_done tweaks; then
	log "applying the sweet-root tweaks"
	mkdir -p "$WORK/mnt"
	sudo mkdir -p "$WORK/mnt"
	sudo mount -t hfsplus -o loop,force "$OUT" "$WORK/mnt"
	sudo python3 tools/sweet-root-tweaks.py "$WORK/mnt"
	sudo umount "$WORK/mnt"
	log "fsck after the tweaks"
	fsck.hfsplus -f -y "$OUT" | grep -v 'Illegal name' || true
	fsck.hfsplus -f -n "$OUT"
	mark_done tweaks
fi

# 7. the sparse image fastboot flashes
if [ ! -f "$SPARSE" ]; then
	log "converting to a sparse image"
	python3 work/raw2simg.py "$OUT" "$SPARSE"
fi

ls -l "$OUT" "$SPARSE"
df -h / | tail -1
log "done: $SPARSE"
