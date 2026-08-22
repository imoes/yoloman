#!/usr/bin/env bash
# Work the directive gap to the end, in chunks, resumable — the honest way to run 2441 mining calls.
#
# 5842 paths carry a codec decided at the bytes and not one directive. 2441 of those have grounding and are
# not data tables; at the observed ~1.6 paths a minute that is about 25 hours. A single invocation with 2441
# arguments would be one long-running process whose failure loses the queue, so this drives the miner in
# chunks and re-reads the catalog between them: a path that got directives is skipped, so stopping and
# restarting costs nothing.
#
# ONE PROCESS AT A TIME, deliberately. The two miners would write configs/config_directives.json after every
# path and clobber each other — the file is the queue's state as well as its output. laguna runs on
# OpenRouter rather than the shared llama.cpp endpoint, so the reason here is data safety, not politeness.
#
#   scripts/mine-directive-gap.sh <work-list> [chunk-size]
set -u
cd /home/mutkluge/Dev/code/yolo-man
WORK=${1:?usage: mine-directive-gap.sh <work-list> [chunk]}
CHUNK=${2:-50}
SCRATCH=$(dirname "$WORK")
LOG="$SCRATCH/mine-gap.log"
CORPUS="$SCRATCH/corpus_both.jsonl"
MAN="$SCRATCH/deb_man/corpus.jsonl"

while :; do
  # The remaining queue, recomputed from the catalog every round — that is what makes this resumable.
  todo=$(bossman/.venv-host/bin/python - "$WORK" <<'PY'
import json, sys
from pathlib import Path
have = json.loads(Path("configs/config_directives.json").read_text())
todo = [p for p in Path(sys.argv[1]).read_text().split()
        if p not in have and p.rsplit("/", 1)[-1] not in have]
print("\n".join(todo))
PY
)
  count=$(printf '%s\n' "$todo" | grep -c . || true)
  [ "$count" -eq 0 ] && { echo "$(date +%H:%M) fertig — die Schere ist geschlossen" >>"$LOG"; break; }
  batch=$(printf '%s\n' "$todo" | head -n "$CHUNK" | tr '\n' ' ')
  echo "$(date +%H:%M) noch $count Pfade, nächste $CHUNK" >>"$LOG"
  ( cd bossman/scripts && env http_proxy=http://proxy.example.internal:80 \
      https_proxy=http://proxy.example.internal:80 \
      no_proxy=llm.example.internal,localhost,127.0.0.1 QUALIFY_NO_SEARXNG=1 \
      ../.venv-host/bin/python rh_mine_directives.py --engine laguna \
      --corpus "$CORPUS" --man-corpus "$MAN" --remine $batch ) >>"$LOG" 2>&1
  # The linter after every chunk, because a fresh mine carries the same defect classes as the old catalog:
  # zero ranges, ranges on a bool, fractional int defaults. Measured every single time so far.
  bossman/.venv-host/bin/python bossman/scripts/lint_directive_catalog.py --corpus "$CORPUS" --write \
    >>"$LOG" 2>&1
done
