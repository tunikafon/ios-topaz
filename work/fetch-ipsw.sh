#!/bin/bash
# Fetch one IPSW member with retries around the whole download.
#
#   fetch-ipsw.sh PATTERN [OUTDIR]
#
# remotezip.py already retries single range requests, but a network drop (DNS
# failure, no route) kills it for good. This wrapper restarts it; the .part
# file makes every restart continue where the last one stopped.
set -uo pipefail

REPO=/home/tunikafon/Projects/ios-topaz
URL="https://updates.cdn-apple.com/2025FallFCS/fullrestores/122-77006/1158E502-D76D-4226-AA06-ED5E30CD1111/iPhone10,3,iPhone10,6_16.7.16_20H392_Restore.ipsw"
PATTERN=${1:?usage: fetch-ipsw.sh PATTERN [OUTDIR]}
OUTDIR=${2:-$REPO/work/ipsw}

cd "$REPO"
for attempt in $(seq 1 200); do
	if [ -f "$OUTDIR/$PATTERN" ]; then
		echo "$PATTERN: complete"
		exit 0
	fi
	echo "--- attempt $attempt at $(date +%T)"
	python3 work/remotezip.py "$URL" "$PATTERN" "$OUTDIR" && exit 0
	sleep 15
done
echo "$PATTERN: giving up" >&2
exit 1
