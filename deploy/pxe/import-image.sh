#!/bin/sh
# Import an EXISTING disk image (vmdk/qcow2/raw) as a golden DiskImage — the "I already have an OS"
# path, parallel to installing from an ISO. Runs INSIDE the pxe container (has qemu-img/qemu-nbd/
# partclone/zstd/lvm2/curl); Bossman docker-execs it after POST /images/import created the image.
#
# It mirrors the restore's checkin: the container reports lsblk+sfdisk, Bossman plans (parse_layout →
# manifest + per-volume capture list), the container partclones each volume and streams it up under the
# per-image token, then finishes with the measured used sizes. See docs/pxe-baremetal-imaging.md and
# bossman/bossman/services/imaging.py (the capture/restore contract lives there, not here).
#
# Usage: import-image.sh <source-basename-in-DISK_DIR> <image_id> <image_token> <bossman_url>
set -eu

SRC_NAME="$1"; IMAGE_ID="$2"; TOKEN="$3"; BOSSMAN_URL="$4"
DISK_DIR="${DISK_DIR:-/srv/templates}"
SRC="$DISK_DIR/$SRC_NAME"
NBD=/dev/nbd0
WORK="$DISK_DIR/.import-${IMAGE_ID}.qcow2"

[ -f "$SRC" ] || { echo "import: source not found: $SRC" >&2; exit 2; }

api() { # api <method> <path> [curl-args…]  — always carries the image token
    m="$1"; p="$2"; shift 2
    curl -fsS -X "$m" -H "X-Image-Token: ${TOKEN}" "${BOSSMAN_URL}${p}" "$@"
}
fail() {
    echo "import: FAILED: $*" >&2
    # Best-effort: mark the image failed so the WebUI shows the reason instead of a stuck "capturing".
    api POST "/api/v1/images/${IMAGE_ID}/import-failed" -H 'Content-Type: application/json' \
        --data "$(printf '{"error":%s}' "$(printf 'import: %s' "$*" | jq -Rs .)")" >/dev/null 2>&1 || true
    cleanup
    exit 1
}

cleanup() {
    umount /mnt/probe 2>/dev/null || true
    vgchange -an >/dev/null 2>&1 || true
    qemu-nbd -d "$NBD" >/dev/null 2>&1 || true
    rm -f "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

# 1. Normalise to qcow2 (our working format) and attach it as a block device. qemu-nbd reads vmdk/raw
#    directly, but converting first gives one predictable, sparse copy to read from.
echo "import: converting ${SRC_NAME} → qcow2"
qemu-img convert -O qcow2 "$SRC" "$WORK" || fail "qemu-img convert"
modprobe nbd max_part=16 2>/dev/null || true
qemu-nbd --connect="$NBD" -f qcow2 "$WORK" || fail "qemu-nbd connect"
# Let partitions + any LVM show up.
partprobe "$NBD" 2>/dev/null || true
vgscan --mknodes >/dev/null 2>&1 || true
vgchange -ay >/dev/null 2>&1 || true
udevadm settle 2>/dev/null || sleep 1

# 2. Report the layout; Bossman plans it (parse_layout → manifest + the per-volume capture list).
LSBLK="$(lsblk -b --json -O "$NBD" 2>/dev/null)" || fail "lsblk"
SFDISK="$(sfdisk --json "$NBD" 2>/dev/null || echo '{}')"
PLAN="$(printf '{"lsblk":%s,"sfdisk":%s}' "$LSBLK" "$SFDISK" \
        | api POST "/api/v1/images/${IMAGE_ID}/capture-plan" -H 'Content-Type: application/json' --data @-)" \
    || fail "capture-plan"

# The plan: {"manifest":{…}, "volumes":[{"stem","fs","tool","partition","vg","lv"}, …]}. The device path
# is derived HERE (the container owns the nbd/LVM naming): an LV is /dev/<vg>/<lv>, a bare partition is
# ${NBD}p<n>.
MANIFEST="$(printf '%s' "$PLAN" | jq -c '.manifest')"
VOLS="$(printf '%s' "$PLAN" | jq -c '.volumes[]')"
[ -n "$VOLS" ] || fail "capture-plan returned no volumes"

vol_dev() { # reads one volume JSON on stdin → prints its device path
    v="$1"
    vg="$(printf '%s' "$v" | jq -r '.vg // empty')"
    lv="$(printf '%s' "$v" | jq -r '.lv // empty')"
    part="$(printf '%s' "$v" | jq -r '.partition // empty')"
    if [ -n "$vg" ] && [ -n "$lv" ]; then printf '/dev/%s/%s' "$vg" "$lv"; else printf '%sp%s' "$NBD" "$part"; fi
}

# 3. Per volume: stream partclone|zstd up under the stem.
mkdir -p /mnt/probe
printf '%s\n' "$VOLS" | while IFS= read -r v; do
    stem="$(printf '%s' "$v" | jq -r '.stem')"
    tool="$(printf '%s' "$v" | jq -r '.tool')"
    dev="$(vol_dev "$v")"
    [ -b "$dev" ] || fail "volume device missing: $dev (stem $stem)"
    echo "import: capturing ${stem} from ${dev} via ${tool}"
    "$tool" -c -s "$dev" -o - -q 2>/dev/null | zstd -T0 -3 \
        | api PUT "/api/v1/images/${IMAGE_ID}/files/${stem}" -T - \
        || fail "capture/upload of ${stem}"
done

# used_bytes measured in a second pass (a cold, read-only mount; the pipe above ran in a subshell).
printf '%s\n' "$VOLS" | while IFS= read -r v; do
    stem="$(printf '%s' "$v" | jq -r '.stem')"
    dev="$(vol_dev "$v")"
    used=0
    if mount -o ro "$dev" /mnt/probe 2>/dev/null; then
        used="$(df -B1 --output=used /mnt/probe 2>/dev/null | tail -1 | tr -d ' ')"
        umount /mnt/probe 2>/dev/null || true
    fi
    printf '%s\t%s\n' "$stem" "${used:-0}"
done > /tmp/import-used.tsv

# Build the used_bytes object with jq from the tsv.
USED_JSON="$(jq -Rn '[inputs | split("\t") | {(.[0]): (.[1]|tonumber)}] | add // {}' < /tmp/import-used.tsv)"

# 4. Finish: record the manifest + measured usage; Bossman validates and flips the image to `ready`.
printf '{"manifest":%s,"used_bytes":%s}' "$MANIFEST" "$USED_JSON" \
    | api POST "/api/v1/images/${IMAGE_ID}/finish" -H 'Content-Type: application/json' --data @- \
    || fail "finish"

echo "import: DONE — image ${IMAGE_ID} is ready"
