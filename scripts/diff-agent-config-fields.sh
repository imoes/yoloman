#!/usr/bin/env bash
# Prove the agent and Bossman give the SAME answer for /config-fields — the claim "no rule is reimplemented".
#
# The agent serves a recorded projection (bossman/scripts/export_agent_config_projection.py); Bossman computes
# the answer from the rules. If the two ever diverge, the projection is stale or the Go assembly is wrong, and
# a host would show different editable fields depending on who it asked. That is exactly the failure this
# design exists to prevent, so it is measured rather than asserted.
#
#   scripts/diff-agent-config-fields.sh [count] [family]
set -euo pipefail
cd "$(dirname "$0")/.."
COUNT=${1:-60}
FAMILY=${2:-debian}
BOSS=${BOSS:-http://localhost:8123}
WORK=$(mktemp -d)

TOKEN=$(curl -s -m 10 -X POST "$BOSS/api/v1/auth/login" -H 'content-type: application/json' \
  -d "{\"username\":\"${BOSS_USER:-admin}\",\"password\":\"${BOSS_PASS:-admin123}\"}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')

# A SPREAD of paths, not the first N: a codec'd file, a template file and an unknown one exercise the three
# branches, and taking the head of a sorted catalog would only ever test the first.
python3 - "$COUNT" >"$WORK/paths.txt" <<'PY'
import json, sys
n = int(sys.argv[1])
codecs = json.load(open("configs/config_codecs.json"))
index = json.load(open("configs/config_template_index.json"))["base"]["paths"]
parsable = sorted(p for p, r in codecs.items() if isinstance(r, dict) and r.get("codec") not in (None, "none"))
freeform = sorted(p for p, r in codecs.items() if isinstance(r, dict) and r.get("codec") == "none")
templated = sorted(p for p in index if p in codecs)
def spread(xs, k):
    if not xs or k <= 0: return []
    step = max(1, len(xs) // k)
    return xs[::step][:k]
picked = spread(parsable, n // 3) + spread(templated, n // 3) + spread(freeform, n // 3)
picked.append("/etc/definitely/not/recorded.conf")
print("\n".join(dict.fromkeys(picked)))
PY
echo ">> $(grep -c . "$WORK/paths.txt") paths, family=$FAMILY"

# ABSOLUTE, because `go test` runs with the package directory as its CWD — a relative ./configs resolved to
# internal/server/configs, the agent read nothing, and every path came back "unknown" while Bossman answered
# "codec". That looked exactly like a real disagreement.
AGENT_CONFIG_DIR="$PWD/configs" AGENT_DIFF_FAMILY="$FAMILY" \
  AGENT_DIFF_PATHS="$(cat "$WORK/paths.txt")" AGENT_DIFF_OUT="$WORK/agent.json" \
  go test ./internal/server/ -run ConfigFieldsMatchBossman -count=1 >/dev/null

python3 - "$WORK/paths.txt" "$WORK/agent.json" "$BOSS" "$TOKEN" "$FAMILY" <<'PY'
import json, sys, urllib.parse, urllib.request
paths_file, agent_file, boss, token, family = sys.argv[1:6]
agent = json.load(open(agent_file))
paths = [l.strip() for l in open(paths_file) if l.strip()]

# What is compared: the CLAIMS. `template` (the body) and `sample` are content the agent reads from the same
# files Bossman does; comparing them would only test the file copy. These keys are the answer itself.
KEYS = ("write", "format", "separator", "template_name", "reason", "available")
mismatch, missing = [], 0
for p in paths:
    q = urllib.parse.urlencode({"path": p, "family": family})
    req = urllib.request.Request(f"{boss}/api/v1/config-fields?{q}",
                                headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=30) as r:
        want = json.load(r)
    got = agent.get(p) or {}
    for k in KEYS:
        if want.get(k) != got.get(k):
            mismatch.append((p, k, want.get(k), got.get(k)))
    # The field SET, not the field bodies: a missing key is a setting the operator cannot reach.
    wf, gf = set((want.get("fields") or {})), set((got.get("fields") or {}))
    if wf != gf:
        mismatch.append((p, "fields", "±{}".format(len(wf ^ gf)), "bossman-only={} agent-only={}".format(
            sorted(wf - gf)[:3], sorted(gf - wf)[:3])))
    for k in ("withheld", "unsettable", "renderer_gaps", "machine_written"):
        if bool(want.get(k)) != bool(got.get(k)):
            mismatch.append((p, k, bool(want.get(k)), bool(got.get(k))))

print("compared {} paths".format(len(paths)))
if not mismatch:
    print("AGREE on every key — the projection is current and the assembly matches")
else:
    print("DISAGREE on {} claims:".format(len(mismatch)))
    for p, k, want, got in mismatch[:25]:
        print("   {:52s} {:14s} bossman={!r} agent={!r}".format(p[:52], k, want, got))
sys.exit(1 if mismatch else 0)
PY
