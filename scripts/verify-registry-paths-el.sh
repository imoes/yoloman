#!/usr/bin/env bash
# The EL half of the path verification. Same script inside the container, different package manager.
#
# 135 of the 678 names Debian could not fetch exist on ubuntu/redhat/suse, and 9 are plain EL software (bind,
# dovecot). On Debian they produce no verdict at all — correct, and useless. This asks where the package
# actually lives. VERIFY_FAMILY labels every row, because /etc/named.conf is absent on Debian and present on
# EL, and that one label is the difference between a sound withdrawal and a damaging one.
#
#   SCRATCH=<scratchpad> scripts/verify-registry-paths-el.sh [chunk]
set -u
cd "$(dirname "$0")/.."
LOCK=/tmp/verify-registry-paths-el.lock
exec 9>"$LOCK"
flock -n 9 || { echo "already running (lock $LOCK)"; exit 0; }

SCRATCH=${SCRATCH:?set SCRATCH to the scratchpad directory}
CHUNK=${1:-100}
PROXY=${PROXY:-http://proxy.example.internal:80}
IN=${IN:-$SCRATCH/verify_in_el.json}
OUT=${OUT:-$SCRATCH/verify_el}
LOG="$SCRATCH/verify-paths-el.log"
mkdir -p "$OUT"

while :; do
  before=$(python3 -c "import json;print(len(json.load(open('$OUT/verify_state.json'))))" 2>/dev/null || echo 0)
  docker run --rm -e VERIFY_FAMILY=redhat -e http_proxy="$PROXY" -e https_proxy="$PROXY" \
    -v "$PWD/bossman/scripts/verify_registry_paths.py":/verify.py:ro \
    -v "$IN":/in.json:ro -v "$OUT":/out \
    almalinux:9 sh -c "dnf install -y -q python3 cpio >/dev/null 2>&1; python3 /verify.py --limit $CHUNK" \
    >>"$LOG" 2>&1
  after=$(python3 -c "import json;print(len(json.load(open('$OUT/verify_state.json'))))" 2>/dev/null || echo 0)
  echo "$(date +%H:%M) $after Pakete geprüft (+$((after-before)))" >>"$LOG"
  [ "$after" -gt "$before" ] || { echo "$(date +%H:%M) fertig oder blockiert" >>"$LOG"; break; }
done
