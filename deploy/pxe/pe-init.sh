#!/bin/sh
# Runs inside the RAM PE on boot (pe-provision.service): read the secret + Bossman URL off the kernel
# command line, check in with the target's MAC + disks, then execute the restore `steps` Bossman returns
# (partclone/lvm/grow/grub/offline-enrol), reporting each to /netboot/progress. Reboots once, into the
# freshly installed system. The steps come from imaging.restore_steps; this is just their runner.
set -u

_cmd() { tr ' ' '\n' < /proc/cmdline | sed -n "s/^$1=//p" | head -1; }
SECRET=$(_cmd netboot_secret)
BOSSMAN=$(_cmd bossman_url)
if [ -z "$SECRET" ] || [ -z "$BOSSMAN" ]; then
    echo "pe-init: netboot_secret / bossman_url missing on the kernel command line" >&2
    exit 1
fi

# The MAC the job is armed against, and the disk inventory the plan is computed from.
MAC=$(cat /sys/class/net/*/address 2>/dev/null | grep -v '^00:00:00:00:00:00$' | head -1)
BLK=$(lsblk -b --json | jq -c '.blockdevices')

req() { curl -fsS -H "X-Netboot-Secret: $SECRET" -H "Content-Type: application/json" "$@"; }

# Wait for the network to actually be reachable before checking in. live-boot brought the interface up
# with ip=dhcp in the initramfs, but by the time systemd runs this unit the route/DNS may lag a moment —
# so poll Bossman until it answers rather than failing on the first try.
i=0
while [ "$i" -lt 40 ]; do
    curl -fsS -m 4 -o /dev/null "$BOSSMAN/healthz" 2>/dev/null && break
    echo "pe-init: waiting for the network / Bossman ($BOSSMAN)… ($i)"; sleep 3; i=$((i + 1))
done

RESP=$(req --retry 5 --retry-all-errors --retry-delay 3 -X POST "$BOSSMAN/api/v1/netboot/checkin" \
    -d "$(jq -cn --arg mac "$MAC" --argjson blk "$BLK" '{mac:$mac, blockdevices:$blk}')") || {
    echo "pe-init: check-in failed for $MAC" >&2; exit 1; }

JOB=$(printf '%s' "$RESP" | jq -r '.job_id')
printf '%s' "$RESP" | jq -r '.sfdisk_script // ""' > /tmp/target.sfdisk   # restore_steps reads this file
echo "pe-init: job $JOB, $(printf '%s' "$RESP" | jq '.steps | length') steps"

progress() {  # step_index, extra jq fields...
    idx=$1; shift
    req -X POST "$BOSSMAN/api/v1/netboot/progress/$JOB" \
        -d "$(jq -cn --argjson i "$idx" "$@" '{step_index:$i} + $extra')" >/dev/null 2>&1 || true
}

N=$(printf '%s' "$RESP" | jq '.steps | length')
i=0
while [ "$i" -lt "$N" ]; do
    NAME=$(printf '%s' "$RESP" | jq -r ".steps[$i].name")
    SHELL_CMD=$(printf '%s' "$RESP" | jq -r ".steps[$i].shell // empty")
    CHROOT=$(printf '%s' "$RESP" | jq -r ".steps[$i].chroot // false")
    pre="chroot /mnt/target"; [ "$CHROOT" = "true" ] || pre=""
    if [ -n "$SHELL_CMD" ]; then
        OUT=$($pre /bin/sh -c "$SHELL_CMD" 2>&1); RC=$?
    else
        ARGV=$(printf '%s' "$RESP" | jq -r '.steps['"$i"'].argv | map(@sh) | join(" ")')
        OUT=$(eval "$pre $ARGV" 2>&1); RC=$?
    fi
    if [ "$RC" -ne 0 ]; then
        progress "$i" --argjson extra "$(jq -cn --arg e "$NAME: $OUT" '{failed:true, error:$e, log:("✗ "+$e)}')"
        echo "pe-init: step $i ($NAME) failed rc=$RC: $OUT" >&2
        exit 1
    fi
    progress "$i" --argjson extra "$(jq -cn --arg l "✓ $NAME" '{log:$l}')"
    i=$((i + 1))
done

progress "$N" --argjson extra '{"done":true,"log":"restore complete"}'
echo "pe-init: restore complete — rebooting into the installed system"
sync
sleep 2
reboot -f
