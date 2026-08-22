#!/usr/bin/env bash
# Work the directive gap to the end, in chunks, resumable — the honest way to run a thousand mining calls.
#
# 5842 paths carry a codec decided at the bytes and not one directive. This drives the miner in chunks and
# re-reads the queue from the catalog between them, so a path that got directives is skipped and stopping
# costs nothing.
#
# ONE PROCESS AT A TIME, deliberately. Two miners would write configs/config_directives.json after every path
# and clobber each other — that file is the queue's state as well as its output. laguna runs on OpenRouter
# rather than the shared llama.cpp endpoint, so the reason here is data safety, not politeness.
#
# THE QUEUE MUST CARRY THE GATE'S CONDITION, not merely "documentation exists". The first run failed 49 of 50
# paths with "documentation is not about this file (0% of its keys appear)" — Apache conf-available fragments
# grounded against the apache2 man page. A page existing is necessary and nowhere near sufficient: the miner
# then asks whether that page MENTIONS the file's own keys. Computing doc_is_about offline first cut 2377
# candidates to 1087 and saved 1290 futile model calls.
#
# AND A FAILURE IS AN ANSWER TOO. The queue is "not in the catalog", so a path that fails PERMANENTLY stays at
# its head and is asked again every round — measured: 47 of 50 failed, the queue fell by 3, and the next chunk
# requested the same 47. Failures are therefore remembered in mine-gap-skip.txt and not paid for twice.
# DELETE that file to retry everything, which is what you want after fixing a cause: the unreachable
# comment-fallback made 32 paths fail for a reason that no longer exists.
#
#   scripts/mine-directive-gap.sh <work-list> [chunk-size]
set -u
cd /home/mutkluge/Dev/code/yolo-man

# ONE DRIVER, ENFORCED. I started a second one while the first was still working and had two miners writing
# configs/config_directives.json after every path — the exact clobbering the comment above warns about, done
# by hand. A lock file is cheaper than remembering.
LOCK=/tmp/mine-directive-gap.lock
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "$(date +%H:%M) ein Treiber läuft bereits (Lock $LOCK) — dieser beendet sich" >&2
  exit 0
fi
WORK=${1:?usage: mine-directive-gap.sh <work-list> [chunk]}
CHUNK=${2:-50}
SCRATCH=$(dirname "$WORK")
LOG="$SCRATCH/mine-gap.log"
SKIP="$SCRATCH/mine-gap-skip.txt"
CORPUS="$SCRATCH/corpus_both.jsonl"
MAN="$SCRATCH/deb_man/corpus.jsonl"
QUEUE="$SCRATCH/mine-gap-queue.txt"

while :; do
  # The remaining queue, recomputed from the catalog and the skip list every round — that is what makes this
  # resumable and what stops it spinning on a path nothing can mine.
  bossman/.venv-host/bin/python bossman/scripts/mine_gap_queue.py "$WORK" "$SKIP" >"$QUEUE"
  count=$(grep -c . "$QUEUE" || true)
  if [ "$count" -eq 0 ]; then
    echo "$(date +%H:%M) fertig — die Schere ist geschlossen" >>"$LOG"
    break
  fi
  batch=$(head -n "$CHUNK" "$QUEUE" | tr '\n' ' ')
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
  # AND THE HONESTY PASSES, here because this is the one moment nothing else writes the catalog. Each fresh
  # mine can produce the same two defects the old catalog had: a key that exists in no documentation
  # (decide_documented_keys, 13 s) and a catalog attached to the wrong file of the right package
  # (find_foreign_catalogs, 3 s) — the newly mined braille tables were grounded on brltty's man page and came
  # out carrying brltty.conf's directives, caught the round after they were created. Every chunk, because 16
  # seconds against a chunk that takes minutes is not worth batching.
  bossman/.venv-host/bin/python bossman/scripts/decide_documented_keys.py "$CORPUS" "$MAN" --write \
    >>"$LOG" 2>&1
  bossman/.venv-host/bin/python bossman/scripts/find_foreign_catalogs.py "$CORPUS" --write >>"$LOG" 2>&1
  # AND THE PROJECTION THE STANDALONE AGENT SERVES, re-recorded here for the same reason the honesty passes
  # run here: this is the one moment nothing else writes the catalog. Every mined path can add directive keys,
  # and a host serving yesterday's projection offers fewer settings than Bossman does for the same file —
  # a disagreement with no visible cause. 6 seconds against a chunk that takes minutes.
  bossman/.venv-host/bin/python bossman/scripts/export_agent_config_projection.py --write >>"$LOG" 2>&1
  # Whatever this chunk asked for and did not get is remembered, so the next round moves on.
  head -n "$CHUNK" "$QUEUE" | bossman/.venv-host/bin/python bossman/scripts/mine_gap_queue.py --failed \
    >>"$SKIP"
done
