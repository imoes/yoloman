#!/usr/bin/env bash
# Patch collect.services / collect.drop_metrics into an agent's /etc/agentic-mcp/config.yaml
# and restart it.
#
# WHY A SCRIPT AND NOT THE ROLLOUT ENDPOINT: `update-bundled` replaces only the BINARY. config.yaml is
# packaged as config.yaml.example with `noreplace`, precisely so a rollout never overwrites an operator's
# file — which also means these two keys have to be set per host, or the new agent keeps collecting
# service_* and nothing about the 38.8% row share changes.
#
# Idempotent: run it twice and the second run reports "already set". It rewrites only the two keys
# inside the `collect:` block and leaves every other line, comment and ordering untouched.
#
# Usage:
#   scripts/patch-agent-collect-config.sh [--dry-run] [--user root] host [host…]
#
# Verify one host first:
#   scripts/patch-agent-collect-config.sh --dry-run vpp0221.example.com

set -euo pipefail

SSH_USER="${AGENT_SSH_USER:-root}"
DRY=0
HOSTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --user) SSH_USER="$2"; shift 2 ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) HOSTS+=("$1"); shift ;;
  esac
done
[ ${#HOSTS[@]} -gt 0 ] || { echo "usage: $0 [--dry-run] [--user U] host [host…]" >&2; exit 2; }

CONFIG=/etc/agentic-mcp/config.yaml

# The patcher runs ON the target, in python3 (present on every Debian/RHEL host we deploy to). Line-based
# and scoped to the `collect:` block rather than a YAML round-trip, because a round-trip would reformat
# the whole file and discard the comments that explain every other setting.
read -r -d '' PATCHER <<'PY' || true
import re, shutil, sys, time

CONFIG = "/etc/agentic-mcp/config.yaml"
DROP = ["disk_read_time_ms_total", "disk_write_time_ms_total"]
dry = "--dry-run" in sys.argv

try:
    lines = open(CONFIG).read().splitlines()
except FileNotFoundError:
    print("MISSING: %s — is the agent installed?" % CONFIG)
    sys.exit(3)

# Find `collect:` at column 0 and the extent of its block (until the next column-0 key).
start = None
for i, ln in enumerate(lines):
    if re.match(r"^collect:\s*$", ln):
        start = i
        break
if start is None:
    print("NO collect: BLOCK — refusing to guess where to add it")
    sys.exit(4)

end = len(lines)
for i in range(start + 1, len(lines)):
    if lines[i] and not lines[i][0].isspace() and not lines[i].lstrip().startswith("#"):
        end = i
        break

block = lines[start + 1 : end]
changed = []

# 1. services: false  (replace in place if present, else append to the block)
for i, ln in enumerate(block):
    if re.match(r"^\s*services:\s", ln):
        if re.match(r"^\s*services:\s*false\s*$", ln):
            break
        block[i] = re.sub(r"(^\s*services:\s*).*$", r"\1false", ln)
        changed.append("services -> false")
        break
else:
    block.append("  services: false")
    changed.append("services added as false")

# 2. drop_metrics — only add names that are not already listed, so a hand-added entry survives.
di = next((i for i, ln in enumerate(block) if re.match(r"^\s*drop_metrics:\s*$", ln)), None)
if di is None:
    if any(re.match(r"^\s*drop_metrics:\s*\[", ln) for ln in block):
        print("drop_metrics is in FLOW style ([a, b]) — not editing it by hand, do it yourself")
        sys.exit(5)
    block.append("  drop_metrics:")
    for m in DROP:
        block.append("    - %s" % m)
    changed.append("drop_metrics added (%d entries)" % len(DROP))
else:
    j = di + 1
    existing = []
    while j < len(block) and re.match(r"^\s*-\s+\S", block[j]):
        existing.append(block[j].split("-", 1)[1].strip())
        j += 1
    missing = [m for m in DROP if m not in existing]
    for k, m in enumerate(missing):
        block.insert(j + k, "    - %s" % m)
    if missing:
        changed.append("drop_metrics += %s" % ",".join(missing))

if not changed:
    print("already set — no change")
    sys.exit(0)

out = "\n".join(lines[: start + 1] + block + lines[end:]) + "\n"
if dry:
    print("WOULD CHANGE: %s" % "; ".join(changed))
    print("--- resulting collect: block ---")
    print("\n".join(["collect:"] + block))
    sys.exit(0)

backup = "%s.bak-%s" % (CONFIG, time.strftime("%Y%m%d-%H%M%S"))
shutil.copy2(CONFIG, backup)
open(CONFIG, "w").write(out)
print("CHANGED: %s (backup: %s)" % ("; ".join(changed), backup))
PY

for host in "${HOSTS[@]}"; do
  echo "=== ${host} ==="
  if [ "$DRY" = 1 ]; then
    # shellcheck disable=SC2029  # PATCHER is deliberately expanded locally
    ssh -o BatchMode=yes -o ConnectTimeout=15 "${SSH_USER}@${host}" \
      "python3 - --dry-run" <<<"$PATCHER" || echo "  (failed on ${host})"
    continue
  fi
  ssh -o BatchMode=yes -o ConnectTimeout=15 "${SSH_USER}@${host}" \
    "python3 -" <<<"$PATCHER" || { echo "  (patch failed on ${host}, NOT restarting)"; continue; }
  # Restart only after a successful patch: a half-written config plus a restart is how a host goes
  # silent. `is-active` is the success signal, same as the SSH deploy uses.
  ssh -o BatchMode=yes -o ConnectTimeout=15 "${SSH_USER}@${host}" \
    'systemctl restart agentic-mcp.service && systemctl is-active agentic-mcp.service' \
    || echo "  (agent did NOT come back on ${host} — check it)"
done
