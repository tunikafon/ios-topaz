#!/bin/bash
# Unpack the kernel artifact of the xnu.yml GitHub Actions run.
#
#   unpack-kernel.sh [ZIP]
#
# The zip is the "xnu-kernel" artifact downloaded from
# https://github.com/MakrSas/ios-topaz/actions/runs/39419628786
# (GitHub asks for a login to download artifacts).
set -euo pipefail

REPO=/home/tunikafon/Projects/ios-topaz
cd "$REPO"
ZIP=${1:-$(ls -t xnu/out/*.zip 2>/dev/null | head -1)}
[[ -n $ZIP && -f $ZIP ]] || { echo "usage: $0 <xnu-kernel.zip>" >&2; exit 2; }

mkdir -p xnu/out
unzip -o -j "$ZIP" -d xnu/out
ls -l xnu/out/kernel.development.sweet
file xnu/out/kernel.development.sweet 2>/dev/null || true
