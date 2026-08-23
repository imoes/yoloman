#!/usr/bin/env bash
# Ask every /etc/<packagename> claim whether the package ships anything there. Resumable, one process.
#
# 2248 of the registry's 14599 entries have a path that is exactly the package's own name, 1342 of them
# claiming confidence "high". A first measured sample of 33 found 33 absent — no file, no directory, and no
# maintainer script that would create one. Every one of those is offered in the file catalog an operator
# browses as a config file to edit.
#
# ONE PROCESS, because the container appends to verify_paths.jsonl and rewrites verify_state.json per package.
# Resumable per package, so stopping costs one download.
#
#   scripts/verify-registry-paths.sh [chunk]
set -u
cd "$(dirname "$0")/.."
LOCK=/tmp/verify-registry-paths.lock
exec 9>"$LOCK"
flock -n 9 || { echo "already running (lock $LOCK)"; exit 0; }

SCRATCH=${SCRATCH:?set SCRATCH to the scratchpad directory}
CHUNK=${1:-400}
PROXY=${PROXY:-${YOLOMAN_HTTP_PROXY}}
# IN and OUT are overridable because the resumable state is keyed by PACKAGE, not by path: a package already
# verified for /etc/foo would be skipped when a later work list asks about /etc/foo/bar.conf. A second
# question therefore gets its own state directory, and record_path_verdicts.py merges the results.
IN=${IN:-$SCRATCH/verify_in.json}
OUT=${OUT:-$SCRATCH/verify}
LOG="$SCRATCH/verify-paths.log"
mkdir -p "$OUT"

while :; do
  before=$(python3 -c "import json;print(len(json.load(open('$OUT/verify_state.json'))))" 2>/dev/null || echo 0)
  docker run --rm -e http_proxy="$PROXY" -e https_proxy="$PROXY" \
    -v "$PWD/bossman/scripts/verify_registry_paths.py":/verify.py:ro \
    -v "$IN":/in.json:ro -v "$OUT":/out \
    debian:12 sh -c "apt-get -qq update >/dev/null 2>&1 && \
      apt-get -qq install -y --no-install-recommends python3 >/dev/null 2>&1 && \
      python3 /verify.py --limit $CHUNK" >>"$LOG" 2>&1
  after=$(python3 -c "import json;print(len(json.load(open('$OUT/verify_state.json'))))" 2>/dev/null || echo 0)
  echo "$(date +%H:%M) $after Pakete geprüft (+$((after-before)))" >>"$LOG"
  # Record after every chunk, so the API can already quote what has been measured. The record holds only
  # measured paths — an unmeasured one gets no entry, which is not the same claim as "there is a file".
  bossman/.venv-host/bin/python bossman/scripts/record_path_verdicts.py "$OUT/verify_paths.jsonl" --write \
    >>"$LOG" 2>&1
  # A chunk that adds nothing means the work list is exhausted (or the container cannot start) — either way
  # looping again would only repeat it.
  [ "$after" -gt "$before" ] || { echo "$(date +%H:%M) fertig oder blockiert" >>"$LOG"; break; }
done
