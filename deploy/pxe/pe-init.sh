#!/bin/sh
# Runs inside the RAM PE on boot (pe-provision.service): read the secret + Bossman URL off the kernel
# command line, check in with the target's MAC + disks, then run the RESTORE as two Ansible playbooks
# via the agent's `run-runbook` — phase 1 (PE context: partition/LVM/image/grow) against the raw devices,
# phase 2 (chroot /mnt/target: bootloader/initramfs/identity/network) — plus the agent enrol. Reboots
# once, into the freshly installed system. Bossman resolves the layout into the playbook vars; this is
# just their runner. See services/imaging.restore_vars + configs/wizard_playbooks/restore-*-phase.yml.
set -u

AGENT=/usr/bin/agentic-mcpd
MODULES_DIR=/usr/share/agentic-provision-modules   # PE-baked provisioning modules (+ embedded set in the binary)
TARGET=/mnt/target

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

# Wait for the network to actually be reachable before checking in (live-boot brought the interface up
# with ip=dhcp, but route/DNS can lag a moment behind this unit).
i=0
while [ "$i" -lt 40 ]; do
    curl -fsS -m 4 -o /dev/null "$BOSSMAN/healthz" 2>/dev/null && break
    echo "pe-init: waiting for the network / Bossman ($BOSSMAN)… ($i)"; sleep 3; i=$((i + 1))
done

RESP=$(req --retry 5 --retry-all-errors --retry-delay 3 -X POST "$BOSSMAN/api/v1/netboot/checkin" \
    -d "$(jq -cn --arg mac "$MAC" --argjson blk "$BLK" '{mac:$mac, blockdevices:$blk}')") || {
    echo "pe-init: check-in failed for $MAC" >&2; exit 1; }

JOB=$(printf '%s' "$RESP" | jq -r '.job_id')
DISK=/dev/$(printf '%s' "$RESP" | jq -r '.target_disk')
echo "pe-init: job $JOB → $DISK"

# jq extractor for a top-level field of the checkin response, as compact JSON.
field() { printf '%s' "$RESP" | jq -c "$1"; }

progress() {  # phase_index, extra jq object (e.g. '{log:"…"}' or '{failed:true,error:"…"}')
    idx=$1; extra=$2
    req -X POST "$BOSSMAN/api/v1/netboot/progress/$JOB" \
        -d "$(jq -cn --argjson i "$idx" --argjson extra "$extra" '{step_index:$i} + $extra')" >/dev/null 2>&1 || true
}
fail_phase() {  # phase_index, message
    progress "$1" "$(jq -cn --arg e "$2" '{failed:true, error:$e, log:("✗ "+$e)}')"
    echo "pe-init: $2" >&2
    exit 1
}

# The sfdisk dump the disk_partition module replays (empty when LVM sits on the raw disk).
field '.sfdisk_script // ""' | jq -r . > /tmp/target.sfdisk 2>/dev/null || printf '%s' "$(field '.sfdisk_script // ""')" > /tmp/target.sfdisk
field '.pe_runbook'     > /tmp/pe.json
field '.target_runbook' > /tmp/target.json

# A machine being deployed must have a BLANK target disk — refuse (never wipe) if it already carries a
# partition table or a filesystem/LVM signature. (disk_partition guards too, but it is skipped for
# LVM-on-raw layouts, so the guard also lives here.)
if [ -n "$(lsblk -rno NAME "$DISK" 2>/dev/null | tail -n +2)" ] || [ -n "$(wipefs "$DISK" 2>/dev/null)" ]; then
    fail_phase 0 "target disk $DISK is not blank (found partitions or a filesystem/LVM signature) — a machine being deployed must have an empty disk"
fi

run_runbook() {  # runbook.json, params-json, [--chroot ROOT]
    rb=$1; params=$2; shift 2
    "$AGENT" run-runbook "$rb" --modules-dir "$MODULES_DIR" --params "$params" "$@" 2>&1
}

# ── Phase 1 — PE context: partition, LVM, restore images, grow. ─────────────────────────────────────
OUT=$(run_runbook /tmp/pe.json "$(field '.pe_vars')") || fail_phase 0 "restore (PE phase) failed: $OUT"
progress 0 "$(jq -cn '{log:"✓ restore (PE phase): partition/LVM/image/grow"}')"

# Mount the restored target tree (parents-first) + the pseudo-filesystems a chroot needs, so phase 2 can
# chroot into /mnt/target (grub reads /sys, dpkg wants /proc, device nodes come from /dev).
mkdir -p "$TARGET"
printf '%s' "$RESP" | jq -c '.mounts[]?' | while IFS= read -r m; do
    dev=$(printf '%s' "$m" | jq -r '.device'); mp=$(printf '%s' "$m" | jq -r '.mountpoint')
    mkdir -p "$mp" && mount "$dev" "$mp" || { echo "pe-init: mount $dev → $mp failed" >&2; exit 1; }
done || fail_phase 1 "mounting the target tree failed"
for src in /dev /proc /sys /run; do
    mkdir -p "$TARGET$src"; mount --rbind "$src" "$TARGET$src" || fail_phase 1 "bind $src failed"
done

# ── Phase 2 — chroot context: bootloader, initramfs, identity, network. ─────────────────────────────
OUT=$(run_runbook /tmp/target.json "$(field '.target_vars')" --chroot "$TARGET") \
    || fail_phase 1 "configure (target phase) failed: $OUT"
progress 1 "$(jq -cn '{log:"✓ configure (target phase): bootloader/initramfs/identity/network"}')"

# ── Phase 3 — enrol the agent into the target (token-specific dpkg install; chroot shell steps). ────
N=$(printf '%s' "$RESP" | jq '.agent_install_steps | length')
i=0
while [ "$i" -lt "$N" ]; do
    NAME=$(printf '%s' "$RESP" | jq -r ".agent_install_steps[$i].name")
    SHELL_CMD=$(printf '%s' "$RESP" | jq -r ".agent_install_steps[$i].shell // empty")
    CHROOT=$(printf '%s' "$RESP" | jq -r ".agent_install_steps[$i].chroot // false")
    pre="chroot $TARGET"; [ "$CHROOT" = "true" ] || pre=""
    if [ -n "$SHELL_CMD" ]; then
        OUT=$($pre /bin/sh -c "$SHELL_CMD" 2>&1); RC=$?
    else
        ARGV=$(printf '%s' "$RESP" | jq -r '.agent_install_steps['"$i"'].argv | map(@sh) | join(" ")')
        OUT=$(eval "$pre $ARGV" 2>&1); RC=$?
    fi
    [ "$RC" -eq 0 ] || fail_phase 2 "enrol step '$NAME' failed rc=$RC: $OUT"
    i=$((i + 1))
done
progress 2 "$(jq -cn '{log:"✓ enrolled the agent into the target"}')"

# ── Teardown — reverse the binds then the mounts, so nothing is busy at reboot. ─────────────────────
for src in /run /sys /proc /dev; do umount -lR "$TARGET$src" 2>/dev/null || true; done
printf '%s' "$RESP" | jq -r '.mounts[]?.mountpoint' | sort -r | while IFS= read -r mp; do umount "$mp" 2>/dev/null || true; done

progress 3 "$(jq -cn '{done:true, log:"restore complete"}')"
echo "pe-init: restore complete — rebooting into the installed system"
sync
sleep 2
reboot -f
