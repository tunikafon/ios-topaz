#!/bin/bash
# Build the topaz boot image: ADT -> payload -> shim -> shim-boot.img.
#
#   build-boot.sh [KERNEL_DEVELOPMENT_SWEET]
#
# Needs xnu/out/kernel.development.sweet (the artifact of the xnu.yml GitHub
# Actions run) and the device tree in research/ipsw-x/d22ap.adt.
set -euo pipefail

REPO=/home/tunikafon/Projects/ios-topaz
cd "$REPO"

KERNEL=${1:-xnu/out/kernel.development.sweet}
[[ -f $KERNEL ]] || { echo "missing kernel: $KERNEL" >&2; exit 1; }
[[ -f research/ipsw-x/d22ap.adt ]] || {
	echo "missing device tree: research/ipsw-x/d22ap.adt" >&2; exit 1; }

export MKBOOTIMG="python3 $REPO/tools/bin/mkbootimg.py"

CMDLINE='debug=0xc serial=3 cpus=4 keepsyms=1 -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_stayon=1 sweetfb_hz=30'
# NOCONSOLE=0 shows the kernel log on the panel (GPU bring-up: watch the steps).
[ "${NOCONSOLE:-1}" = 0 ] || CMDLINE="$CMDLINE sweetfb_noconsole=1"
# GPU bring-up boots: EXTRA_CMDLINE="adreno=2" (or =5 with GPUFW set) work/build-boot.sh KERNEL
[ -z "${EXTRA_CMDLINE:-}" ] || CMDLINE="$CMDLINE $EXTRA_CMDLINE"

echo "=== device tree ==="
# --midmem (NOT --highmem): highmem left phantom RAM that wedged the phone.
# MIDSIZE=0x140000000: 0x80000000 + 5 GiB (this phone's 6 GB, top 0x1c0000000).
MIDSIZE=0x140000000 python3 tools/mkadt.py shim/out/topaz.adt --midmem

echo "=== payload ==="
python3 tools/mkpayload.py "$KERNEL" shim/out/topaz.adt shim/out/payload.bin --cmdline "$CMDLINE" ${GPUFW:+--fw $GPUFW}

echo "=== shim ==="
# build.sh cd's into shim/, so the payload path is relative to shim/
shim/build.sh out/payload.bin

ls -l shim/out/shim-boot.img shim/out/payload.bin shim/out/topaz.adt
