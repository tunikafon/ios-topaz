#!/bin/bash
# Staged build of the iOS 16 root for topaz (Redmi Note 12 4G).
#
# Same result as tools/mkiosroot.sh, but the three disk images are processed
# one at a time and deleted right after the copy, so the peak disk usage is
# ~1 dmg + the HFS+ volume instead of all three dmgs at once.
#
#   mkroot-topaz.sh init   OUT.img [SIZE]                 create the HFS+ volume
#   mkroot-topaz.sh os     OUT.img OS.dmg                 copy the OS root
#   mkroot-topaz.sh sysos  OUT.img SYSOS.dmg              copy the SystemOS cryptex
#   mkroot-topaz.sh appos  OUT.img APPOS.dmg              copy the AppOS cryptex
#   mkroot-topaz.sh finish OUT.img                        keybag, hardlinks, fsck
#
# Between the stages the caller deletes the .dmg it just used (see build-root.sh).
set -euo pipefail

export PATH="$PATH:$HOME/bin"
W=${WORK:-/home/tunikafon/Projects/ios-topaz/work}
cmd=${1:?usage: mkroot-topaz.sh init|os|sysos|appos|finish OUT.img [DMG]}
out=${2:?missing OUT.img}
size=${3:-16G}
work=$W/stage
mkdir -p "$work"

mounts=()
cleanup() {
	local m
	for m in "${mounts[@]:-}"; do
		[ -n "$m" ] || continue
		# As root: the FUSE mount is root-owned, so the user cannot even
		# stat it.  A leftover mount keeps the .dmg open and its space
		# allocated - the copy of the next stage then runs out of disk.
		sudo umount "$m" 2>/dev/null || sudo umount -l "$m" 2>/dev/null || true
		sudo fusermount3 -uz "$m" 2>/dev/null || true
	done
}
trap cleanup EXIT

# apfs-fuse splits its options on ',' (e.g. in iPhone10,3 paths): use a link.
# Keep the .dmg name: apfs-fuse only parses UDIF images when the file name ends
# in .dmg (the OS image is UDIF, the cryptexes are raw APFS).
# Sets APFS_DIR to the volume root inside the mount point.
APFS_DIR=
apfs_mount() {
	local src=$1 tag=$2
	# a stale FUSE mount point of an earlier run blocks rm -rf
	sudo umount -l "$work/$tag" 2>/dev/null || true
	sudo fusermount3 -uz "$work/$tag" 2>/dev/null || true
	rm -rf "$work/$tag" "$work/$tag.dmg" 2>/dev/null || true
	ln -s "$(realpath "$src")" "$work/$tag.dmg"
	mkdir -p "$work/$tag"
	sudo "$(command -v apfs-fuse)" "$work/$tag.dmg" "$work/$tag"
	mounts+=("$work/$tag")
	# apfs-fuse mounts the container and exposes one directory per volume; the
	# iOS images use a volume named "root".  The check has to run as root: the
	# FUSE mount is owned by root and unreadable for the user.
	if sudo test -d "$work/$tag/root"; then APFS_DIR="$work/$tag/root"; else APFS_DIR="$work/$tag"; fi
}

hfs_mount() {
	sudo mkdir -p "$work/root"
	sudo mount -t hfsplus -o loop,force "$out" "$work/root"
	mounts=("$work/root" "${mounts[@]:-}")
}

copy() {
	echo "copying $1 -> ${2#$work/root}"
	sudo mkdir -p "$2"
	sudo rsync -aH --numeric-ids "$1/" "$2/"
}

case $cmd in
init)
	[[ ! -e $out ]] || { echo "refusing to overwrite $out" >&2; exit 1; }
	truncate -s "$size" "$out"
	mkfs.hfsplus -s -J -v iOSRoot "$out"
	;;
os)
	apfs_mount "$3" os
	hfs_mount
	copy "$APFS_DIR" "$work/root"
	sudo umount "$work/root"
	;;
sysos)
	apfs_mount "$3" sysos
	hfs_mount
	copy "$APFS_DIR" "$work/root/private/preboot/Cryptexes/OS"
	sudo umount "$work/root"
	;;
appos)
	apfs_mount "$3" appos
	hfs_mount
	copy "$APFS_DIR" "$work/root/private/preboot/Cryptexes/App"
	sudo umount "$work/root"
	;;finish)
	hfs_mount
	# Shared cache where dyld looks at ignition level 1: hard links, no extra space.
	dsc=private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld
	sudo mkdir -p "$work/root/System/Library/Caches/com.apple.dyld"
	for f in "$work/root/$dsc"/*; do
		sudo ln "$f" "$work/root/System/Library/Caches/com.apple.dyld/${f##*/}"
	done
	# dyld does not search the cryptexes at ignition level 1: hard-link every
	# cryptex file that has no counterpart in the OS root (libobjc-trampolines,
	# libffi-trampolines, libstdc++, ...) to its root path.
	for c in OS App; do
		(cd "$work/root/private/preboot/Cryptexes/$c" && sudo find . ! -type d ! -path './System/Library/Caches/com.apple.dyld/*') |
		while IFS= read -r f; do
			f=${f#./}
			if ! sudo test -e "$work/root/$f" && ! sudo test -L "$work/root/$f"; then
				sudo mkdir -p "$work/root/$(dirname "$f")"
				src="$work/root/private/preboot/Cryptexes/$c/$f"
				# Linux hfsplus cannot hard-link symlinks: copy those.
				if sudo test -L "$src"; then sudo cp -P "$src" "$work/root/$f"; else sudo ln "$src" "$work/root/$f"; fi
			fi
		done
	done
	# logd's log stores: it checks owner _logd (272) and mode, plus a .migrated
	# marker, else it crashes ("BUG IN LIBTRACE: Failed to migrate directory").
	db="$work/root/private/var/db"
	sudo install -d -o 272 -g 272 -m 0751 "$db/diagnostics"
	sudo install -d -o 272 -g 272 -m 0755 "$db/uuidtext" "$db/diagnostics/timesync"
	for d in diagnostics uuidtext diagnostics/timesync; do
		sudo install -o 272 -g 272 -m 0644 /dev/null "$db/$d/.migrated"
	done
	# System keybag for the built-in AppleKeyStore (no passcode).
	sudo install -d -m 0700 -o 0 -g 0 "$work/root/private/var/keybags"
	printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict><key>KeyBagKeys</key><data>U1dFRVQ=</data></dict></plist>' |
		sudo install -m 0600 -o 0 -g 0 /dev/stdin "$work/root/private/var/keybags/systembag.kb"
	sudo umount "$work/root"
	# Linux hfsplus decomposes some non-ASCII names differently from Apple's
	# tables; let fsck_hfs rewrite them, then verify.
	fsck.hfsplus -f -y "$out" | grep -v 'Illegal name' || true
	fsck.hfsplus -f -n "$out"
	;;
*)
	echo "unknown stage $cmd" >&2; exit 2
	;;
esac
