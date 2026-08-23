#!/usr/bin/env bash
# Measure which candidate packages ship a systemd unit. Resumable, one process.
#
# What turns a config-file entry into an installable role is a SERVICE, and the archive says whether there is
# one. Promoting the 398 index-bound templates as kind:"config" would put them in a single listing table —
# all three installer surfaces skip config entries on purpose. A measured unit makes them features.
#
#   SCRATCH=<scratchpad> scripts/find-package-services.sh [chunk]
set -u
cd "$(dirname "$0")/.."
LOCK=/tmp/find-package-services.lock
exec 9>"$LOCK"
flock -n 9 || { echo "already running (lock $LOCK)"; exit 0; }
SCRATCH=${SCRATCH:?set SCRATCH}
CHUNK=${1:-150}
PROXY=${PROXY:-http://proxy.example.internal:80}
OUT="$SCRATCH/services"
LOG="$SCRATCH/find-services.log"
mkdir -p "$OUT"
while :; do
  before=$(python3 -c "import json;print(len(json.load(open('$OUT/services_state.json'))))" 2>/dev/null || echo 0)
  docker run --rm -e http_proxy="$PROXY" -e https_proxy="$PROXY" \
    -v "$PWD/bossman/scripts/find_package_services.py":/f.py:ro \
    -v "$SCRATCH/services_in.json":/in.json:ro -v "$OUT":/out \
    debian:12 sh -c "apt-get -qq update >/dev/null 2>&1 && \
      apt-get -qq install -y --no-install-recommends python3 >/dev/null 2>&1 && \
      python3 /f.py --limit $CHUNK" >>"$LOG" 2>&1
  after=$(python3 -c "import json;print(len(json.load(open('$OUT/services_state.json'))))" 2>/dev/null || echo 0)
  echo "$(date +%H:%M) $after Pakete (+$((after-before)))" >>"$LOG"
  [ "$after" -gt "$before" ] || { echo "$(date +%H:%M) fertig oder blockiert" >>"$LOG"; break; }
done
