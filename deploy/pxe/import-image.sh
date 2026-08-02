#!/bin/sh
# Import an EXISTING disk image (vmdk/qcow2/raw) as a golden DiskImage — the "I already have an OS"
# path, parallel to installing from an ISO. Runs INSIDE the pxe container (qemu-nbd/partclone/zstd/
# lvm2/curl/jq); Bossman docker-execs it detached after POST /images/import created the image.
#
# It mirrors the restore's checkin: the container reports lsblk+sfdisk, Bossman plans (parse_layout →
# manifest + per-volume capture list), the container partclones each volume and streams it up under the
# per-image token, then finishes with the measured used sizes. Progress is reported to /import-progress
# so the WebUI shows a live bar. See docs/pxe-baremetal-imaging.md and bossman/services/imaging.py.
#
# Usage: import-image.sh <source-basename-in-DISK_DIR> <image_id> <image_token> <bossman_url>
set -eu

SRC_NAME="$1"; IMAGE_ID="$2"; TOKEN="$3"; BOSSMAN_URL="$4"
DISK_DIR="${DISK_DIR:-/srv/templates}"
SRC="$DISK_DIR/$SRC_NAME"
NBD=/dev/nbd0

[ -f "$SRC" ] || { echo "import: source not found: $SRC" >&2; exit 2; }

api() { # api <method> <path> [curl-args…]  — always carries the image token
    m="$1"; p="$2"; shift 2
    curl -fsS -X "$m" -H "X-Image-Token: ${TOKEN}" "${BOSSMAN_URL}${p}" "$@"
}
progress() { # <percent> <message> — best-effort live progress for the WebUI bar
    api POST "/api/v1/images/${IMAGE_ID}/import-progress" -H 'Content-Type: application/json' \
        --data "$(printf '{"percent":%s,"message":%s}' "$1" "$(printf '%s' "$2" | jq -Rs .)")" >/dev/null 2>&1 || true
}
fail() {
    echo "import: FAILED: $*" >&2
    # Best-effort: mark the image failed so the WebUI shows the reason instead of a stuck "capturing".
    api POST "/api/v1/images/${IMAGE_ID}/import-failed" -H 'Content-Type: application/json' \
        --data "$(printf '{"error":%s}' "$(printf 'import: %s' "$*" | jq -Rs .)")" >/dev/null 2>&1 || true
    cleanup
    exit 1
}
OVERLAY="$DISK_DIR/.import-${IMAGE_ID}.overlay.qcow2"
# Scope EVERY LVM command to the nbd device, so we can never touch the host's own VGs — belt-and-suspenders
# on top of the container not seeing host /dev at all.
LVM_FILTER='devices{filter=["a|/dev/nbd0p.*|","a|/dev/nbd0|","r|.*|"]}'

cleanup() {
    umount /mnt/probe 2>/dev/null || true
    vgchange -an --config "$LVM_FILTER" >/dev/null 2>&1 || true
    qemu-nbd -d "$NBD" >/dev/null 2>&1 || true
    rm -f "$OVERLAY" 2>/dev/null || true
}
trap cleanup EXIT

# 1. Attach the source via a copy-on-write OVERLAY (RW): LVM has to write metadata to activate a VG, but
#    the operator's source disk must stay byte-for-byte untouched — so all writes land in the throwaway
#    overlay, never the source. The container has NO host /dev (that would expose the host's real disks to
#    a privileged vgchange), so we create the nbd nodes ourselves and activate ONLY the source's VG.
echo "import: attaching ${SRC_NAME} via a copy-on-write overlay"
progress 2 "Hänge Quelle ein…"
modprobe nbd max_part=16 2>/dev/null || true
[ -b "$NBD" ] || mknod "$NBD" b 43 0
SRC_FMT="$(qemu-img info --output=json "$SRC" | jq -r '.format')"
rm -f "$OVERLAY"
qemu-img create -f qcow2 -b "$SRC" -F "$SRC_FMT" "$OVERLAY" >/dev/null || fail "overlay create"
qemu-nbd --connect="$NBD" "$OVERLAY" || fail "qemu-nbd connect"
partprobe "$NBD" 2>/dev/null || true
# The container's /dev has no partition nodes — create nbd0pN (minor N with max_part) so we can read them.
n=1; while [ "$n" -le 16 ]; do [ -b "${NBD}p${n}" ] || mknod "${NBD}p${n}" b 43 "$n"; n=$((n + 1)); done
# Activate only the source's VG (filter-scoped) and create its LV device nodes (no udev in the container).
vgchange -ay --config "$LVM_FILTER" >/dev/null 2>&1 || true
vgmknodes --config "$LVM_FILTER" >/dev/null 2>&1 || true
udevadm settle 2>/dev/null || sleep 1

# 2. Report the layout; Bossman plans it (parse_layout → manifest + the per-volume capture list).
progress 4 "Analysiere Layout…"
LSBLK="$(lsblk -b --json -O "$NBD" 2>/dev/null)" || fail "lsblk"
SFDISK="$(sfdisk --json "$NBD" 2>/dev/null || echo '{}')"

# lsblk can't fill fstype/mountpoint without a udev database (none in the container), so on a COLD capture
# every filesystem reads as null and parse_layout finds nothing. Enrich from blkid (a real fs probe) and,
# for LVM logical volumes, derive the mountpoint from the LV name (root→/, var→/var, …) so roles classify
# correctly. Partitions keep their sfdisk part-type; this only fills the filesystem view.
FSMAP='{}'; MPMAP='{}'
for name in $(lsblk -ln -o NAME "$NBD" 2>/dev/null); do
    dev="/dev/$name"; [ -b "$dev" ] || dev="/dev/mapper/$name"
    t="$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)"
    [ -n "$t" ] && FSMAP="$(printf '%s' "$FSMAP" | jq --arg n "$name" --arg t "$t" '.[$n]=$t')"
    lv="${name#*-}"   # LVM dm name "rootvg-root" → "root"; a bare partition name has no dash → unchanged
    if [ "$name" != "$lv" ]; then
        case "$lv" in
            root) mp=/ ;; boot) mp=/boot ;; home) mp=/home ;; var) mp=/var ;;
            usr) mp=/usr ;; opt) mp=/opt ;; tmp) mp=/tmp ;; srv) mp=/srv ;; *) mp="" ;;
        esac
        [ -n "$mp" ] && MPMAP="$(printf '%s' "$MPMAP" | jq --arg n "$name" --arg m "$mp" '.[$n]=$m')"
    fi
done
LSBLK="$(printf '%s' "$LSBLK" | jq --argjson fs "$FSMAP" --argjson mp "$MPMAP" '
    walk(if type=="object" and has("name") then
        (if .fstype==null and $fs[.name] then .fstype=$fs[.name] else . end)
        | (if .mountpoint==null and $mp[.name] then .mountpoint=$mp[.name] else . end)
    else . end)')"
PLAN="$(printf '{"lsblk":%s,"sfdisk":%s}' "$LSBLK" "$SFDISK" \
        | api POST "/api/v1/images/${IMAGE_ID}/capture-plan" -H 'Content-Type: application/json' --data @-)" \
    || fail "capture-plan"

# The plan: {"manifest":{…}, "volumes":[{"stem","fs","tool","partition","vg","lv"}, …]}. The device path
# is derived HERE (the container owns the nbd/LVM naming): an LV is /dev/<vg>/<lv>, a bare partition is
# ${NBD}p<n>.
MANIFEST="$(printf '%s' "$PLAN" | jq -c '.manifest')"
printf '%s' "$PLAN" | jq -c '.volumes[]' > /tmp/import-vols.jsonl
N="$(wc -l < /tmp/import-vols.jsonl | tr -d ' ')"
[ "${N:-0}" -ge 1 ] || fail "capture-plan returned no volumes"

vol_dev() { # <volume-json> → device path
    vg="$(printf '%s' "$1" | jq -r '.vg // empty')"
    lv="$(printf '%s' "$1" | jq -r '.lv // empty')"
    part="$(printf '%s' "$1" | jq -r '.partition // empty')"
    if [ -n "$vg" ] && [ -n "$lv" ]; then printf '/dev/%s/%s' "$vg" "$lv"; else printf '%sp%s' "$NBD" "$part"; fi
}

# 3. Per volume: stream partclone|zstd up under the stem. Reading the file (not a pipe) keeps the counter.
mkdir -p /mnt/probe
: > /tmp/import-used.tsv
i=0
while IFS= read -r v; do
    i=$((i + 1))
    stem="$(printf '%s' "$v" | jq -r '.stem')"
    tool="$(printf '%s' "$v" | jq -r '.tool')"
    dev="$(vol_dev "$v")"
    [ -b "$dev" ] || fail "volume device missing: $dev (stem $stem)"
    progress "$(( 5 + (i - 1) * 85 / N ))" "Sichere ${stem} (${i}/${N})…"
    echo "import: capturing ${stem} from ${dev} via ${tool}"
    "$tool" -c -s "$dev" -o - -q 2>/dev/null | zstd -T0 -3 \
        | api PUT "/api/v1/images/${IMAGE_ID}/files/${stem}" -T - \
        || fail "capture/upload of ${stem}"
    # Measure used bytes (cold read-only mount) right after capturing this volume.
    used=0
    if mount -o ro "$dev" /mnt/probe 2>/dev/null; then
        used="$(df -B1 --output=used /mnt/probe 2>/dev/null | tail -1 | tr -d ' ')"
        umount /mnt/probe 2>/dev/null || true
    fi
    printf '%s\t%s\n' "$stem" "${used:-0}" >> /tmp/import-used.tsv
    progress "$(( 5 + i * 85 / N ))" "Gesichert ${stem} (${i}/${N})"
done < /tmp/import-vols.jsonl

USED_JSON="$(jq -Rn '[inputs | split("\t") | {(.[0]): (.[1]|tonumber)}] | add // {}' < /tmp/import-used.tsv)"

# 4. Finish: record the manifest + measured usage; Bossman validates and flips the image to `ready`.
progress 95 "Schließe ab…"
printf '{"manifest":%s,"used_bytes":%s}' "$MANIFEST" "$USED_JSON" \
    | api POST "/api/v1/images/${IMAGE_ID}/finish" -H 'Content-Type: application/json' --data @- \
    || fail "finish"

echo "import: DONE — image ${IMAGE_ID} is ready"
