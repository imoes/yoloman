#!/usr/bin/env bash
# Supervisor for qualify_packages.py — runs continuously until every package of every family is qualified.
# Back-to-back passes while there is work; a long idle once there is none.
#
# The idle matters: the queue does drain (measured 2026-08-16 — 9570 packages, 0 pending), and the
# loop then spent every 10s re-running an empty pass PLUS a catalog rebuild and curation, rewriting
# configs/package_catalog.json — a file bind-mounted into the running server and read live. A cheap
# --check-only decides, so an idle tick costs no LLM call and touches no file.
#
# ONE FAMILY AFTER THE OTHER, never both at once: the LLM endpoint is shared and takes one process.
#
# The environment is checked ONCE, up front. This script used to reference ${YOLOMAN_HTTP_PROXY} deep inside
# the loop under `set -u`; the unit never set it, so from 2026-09-02 every pass that found work died on that
# line, systemd restarted it, and 17 054 restarts later nothing had been qualified. A missing variable is a
# configuration error — it is reported once, by name, and the service stops instead of flapping.
set -u

: "${YOLOMAN_HTTP_PROXY:?is not set — set it in agentic-qualify-packages.service}"
: "${YOLOMAN_NO_PROXY_SUFFIX:?is not set — set it in agentic-qualify-packages.service}"
: "${QUALIFY_LLM_URL:?is not set — the LLM endpoint is configured in the unit, never in code}"
: "${QUALIFY_LLM_MODEL:?is not set — the model id that QUALIFY_LLM_URL serves}"

REPO="${AGENTIC_REPO:-/home/mutkluge/Dev/code/yolo-man}"
cd "$REPO/bossman" || { echo "no repo at $REPO/bossman"; exit 1; }

LOG_DIR="${AGENTIC_BATCH_LOG_DIR:-/home/mutkluge/.local/state/agentic-batches}"
mkdir -p "$LOG_DIR"

PY=.venv/bin/python
[ -x "$PY" ] || PY=.venv-host/bin/python

FAMILIES="${QUALIFY_FAMILIES:-debian redhat}"
BUSY_IDLE=10        # work remains: just avoid a tight spin between passes
QUIET_IDLE=900      # queue drained: check back every 15 minutes

export http_proxy="$YOLOMAN_HTTP_PROXY" https_proxy="$YOLOMAN_HTTP_PROXY"
export no_proxy="${YOLOMAN_NO_PROXY_SUFFIX},localhost,127.0.0.1"

while true; do
  worked=0
  for fam in $FAMILIES; do
    ts="$(date -Is)"
    if "$PY" -u -m bossman.tools.qualify_packages --family "$fam" --check-only 2>/dev/null | grep -q -- "— 0 pending"; then
      continue
    fi
    worked=1
    {
      echo "=== $ts qualify pass ($fam) ==="
      "$PY" -u -m bossman.tools.qualify_packages --family "$fam"
      echo "=== $(date -Is) qualify pass ($fam) exit $? ==="
    } >> "$LOG_DIR/qualify.log" 2>&1
  done

  # THE REST OF THE LLM QUEUE, after the family passes and in this order — the same single process, so the shared
  # endpoint still sees one client:
  #   1. rebuild the e2e worklist (cheap, no LLM): a family pass changes which packages have a route
  #   2. per family, the packages the worklist calls `unrouted`, against the exact file the archive measured — EVERY
  #      family: this pass named only Debian, so the 218 unrouted RedHat packages were never queued and the
  #      supervisor went straight to the miner (found 2026-10-15)
  #   3. the validator catalog (check_cmd / daemon_cmd from the packages' own man pages)
  if [ "$worked" = 0 ]; then
    "$PY" -u -m bossman.tools.package_e2e_worklist >> "$LOG_DIR/qualify.log" 2>&1
    for fam in $FAMILIES; do
      if ! "$PY" -u -m bossman.tools.qualify_packages --family "$fam" --from-worklist --check-only 2>/dev/null \
           | grep -q -- "— 0 pending"; then
        worked=1
        { echo "=== $(date -Is) worklist pass ($fam unrouted) ==="
          "$PY" -u -m bossman.tools.qualify_packages --family "$fam" --from-worklist
          echo "=== $(date -Is) worklist pass ($fam) exit $? ==="; } >> "$LOG_DIR/qualify.log" 2>&1
      fi
    done
  fi
  if [ "$worked" = 0 ] && [ "${QUALIFY_MINE_VALIDATORS:-1}" = 1 ]; then
    pending=$("$PY" -u -m bossman.tools.mine_package_validators --llm-url "$QUALIFY_LLM_URL" \
              --llm-model "$QUALIFY_LLM_MODEL" --check-only 2>/dev/null | sed -n 's/.*: \([0-9]*\) package(s).*/\1/p')
    if [ "${pending:-0}" != 0 ]; then
      worked=1
      { echo "=== $(date -Is) validator pass (${pending} pending) ==="
        "$PY" -u -m bossman.tools.mine_package_validators --llm-url "$QUALIFY_LLM_URL" --llm-model "$QUALIFY_LLM_MODEL"
        echo "=== $(date -Is) validator pass exit $? ==="; } >> "$LOG_DIR/validators.log" 2>&1
    fi
  fi

  if [ "$worked" = 0 ]; then
    echo "=== $(date -Is) nothing pending ($FAMILIES, worklist, validators) — idling ${QUIET_IDLE}s ===" >> "$LOG_DIR/qualify.log"
    sleep "$QUIET_IDLE"
    continue
  fi

  {
    # Categorise: rebuild the package catalog so the newly generated codec/template/enum artifacts show up as
    # installable roles in the wizard + Roles & Features. Idempotent + fast.
    echo "=== $(date -Is) rebuild package catalog ==="
    "$PY" -u -m bossman.tools.build_package_catalog
    echo "=== $(date -Is) catalog rebuild exit $? ==="
    # The rebuild only knows what its generators know; the curated RedHat names, the named "not on this
    # family" entries and the user axis live in curate_catalog.py, so it runs AFTER every rebuild —
    # otherwise each pass silently reverts them.
    echo "=== $(date -Is) curate catalog ==="
    "$PY" -u -m bossman.tools.curate_catalog
    # One setting, one value set: a pass mines directives for a path whose bound template already states the set
    # (or the reverse) — copy the evidence across BEFORE the fit check counts it as one-sided (measured: the
    # RedHat pass's /etc/sysconfig/ipmi directives against the openipmi template's yes/no).
    "$PY" -u -m bossman.tools.sync_value_sets --write
    # …and where BOTH state a set and disagree: decided against the man page, abstaining out loud otherwise.
    "$PY" -u -m bossman.tools.audit_value_agreement --write
    "$PY" -u -m bossman.tools.settle_value_disagreements --write
    "$PY" -u -m bossman.tools.check_catalog_fit || echo "!! catalog fit check FAILED — see above"
    echo "=== $(date -Is) curate exit $? ==="
  } >> "$LOG_DIR/qualify.log" 2>&1

  sleep "$BUSY_IDLE"
done
