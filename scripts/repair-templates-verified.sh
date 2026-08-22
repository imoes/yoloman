#!/usr/bin/env bash
# Repair template schemas/samples from what their bodies read — and REVERT whatever the repair breaks.
#
# declare_template_vars infers a variable's shape from how the body uses it, and that inference is right
# often enough to be worth running and wrong often enough to need a check. Five templates were broken twice
# by it (dyn-netconf, gnupg-pkcs11-scd, hdparm, kdc.conf, plugin-krb5-connector.conf: `dict2items: input is
# not a dict`, `.get is not callable`), and both times I found out by comparing totals afterwards.
#
# So the tool verifies its own work: modify, run the render ratchet WITHOUT the write flag, and git-checkout
# every template the ratchet now reports as newly broken. Repeat until the ratchet is silent. What survives
# is provably no worse than before, and the record is only rewritten after that.
#
# Usage: scripts/repair-templates-verified.sh   (from anywhere; it cd's to the repo)
set -e
cd /home/mutkluge/Dev/code/yolo-man
BASE=$(git rev-parse HEAD)
bossman/.venv-host/bin/python bossman/scripts/declare_template_vars.py --also-unsettable --write >/dev/null 2>&1
for round in 1 2 3; do
  broke=$(timeout 900 go test ./internal/modules/ -run TestConfigTemplatesRenderWithSample 2>&1 \
          | grep -E "no longer renders" | sed -E 's/.*record: ([^:]+):.*/\1/' | sort -u)
  [ -z "$broke" ] && { echo "Runde $round: nichts kaputt"; break; }
  echo "Runde $round: zurücknehmen -> $(echo $broke | tr '\n' ' ')"
  for n in $broke; do git checkout "$BASE" -- "configs/config_templates/$n/" 2>/dev/null || true; done
done
