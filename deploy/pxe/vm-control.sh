#!/bin/sh
# QEMU control for the PXE lab. Bossman invokes this via `docker exec <pxe> vm-control.sh <cmd> …`
# (see bossman/bossman/services/vm_lab.py). It launches nested-KVM VMs — an OS install from an ISO to
# build a template, or a diskless PXE-test target that boots the PE and restores the active template —
# and bridges each VM's VNC to a WebSocket for the browser noVNC console.
#
# Deploy assumptions (Block 6 wiring; see docs/pxe-baremetal-imaging.md):
#   * /dev/kvm present (nested virt on the Proxmox host + CPU type `host` on the hal VM).
#   * A layer-2 bridge on ens19 so a PXE-test VM sees dnsmasq's DHCP/TFTP. Name via VM_BRIDGE
#     (default br-ens19); create it once on the host and enslave ens19.
#   * ISO dir bind-mounted at $ISO_DIR, template/target disks at $DISK_DIR.
set -eu

STATE_DIR="${VM_STATE_DIR:-/run/pxe-vms}"
ISO_DIR="${ISO_DIR:-/srv/iso}"
DISK_DIR="${DISK_DIR:-/srv/disks}"
LISTEN_IP="${PXE_LISTEN_IP:-192.0.2.130}"
VM_BRIDGE="${VM_BRIDGE:-br-ens19}"
mkdir -p "$STATE_DIR"

# VNC display N ⇒ TCP 5900+N; the matching noVNC WebSocket is 6080+N. We pick the lowest free display.
_free_display() {
    n=0
    while [ -e "$STATE_DIR/$n/pid" ]; do n=$((n + 1)); done
    echo "$n"
}

_qmp() { echo "$1"; }  # placeholder to keep shellcheck happy about unused helpers on older shells

# start-install <name> <iso-basename> <disk-basename> <disk-gib>
#   Boot an installer ISO with a fresh raw disk attached; the operator drives the install over noVNC.
#   On shutdown the disk is a capture candidate (partclone → PUT /images/{id}/files → /finish).
start_install() {
    name="$1"; iso="$2"; disk="$3"; gib="${4:-40}"
    d="$STATE_DIR/$name"; mkdir -p "$d"
    disp="$(_free_display)"
    [ -f "$DISK_DIR/$disk" ] || qemu-img create -f raw "$DISK_DIR/$disk" "${gib}G" >/dev/null
    qemu-system-x86_64 -enable-kvm -cpu host -m "${VM_RAM_MB:-4096}" -smp "${VM_SMP:-2}" \
        -name "$name" -pidfile "$d/pid" -daemonize \
        -drive file="$DISK_DIR/$disk",format=raw,if=virtio,cache=none \
        -cdrom "$ISO_DIR/$iso" -boot d \
        -netdev user,id=n0 -device virtio-net,netdev=n0 \
        -vnc "$LISTEN_IP:$disp"
    _record "$name" "$disp" "install" "$disk"
    _bridge_vnc "$name" "$disp"
    echo "$name"
}

# start-pxe-test <name> <mac> <disk-basename> <disk-gib>
#   Diskless-boot a target on the ens19 bridge so it PXE-boots the PE and restores the ACTIVE template
#   onto the attached blank disk — the end-to-end harness with no real hardware.
start_pxe_test() {
    name="$1"; mac="$2"; disk="$3"; gib="${4:-60}"
    d="$STATE_DIR/$name"; mkdir -p "$d"
    disp="$(_free_display)"
    [ -f "$DISK_DIR/$disk" ] || qemu-img create -f raw "$DISK_DIR/$disk" "${gib}G" >/dev/null
    qemu-system-x86_64 -enable-kvm -cpu host -m "${VM_RAM_MB:-2048}" -smp "${VM_SMP:-2}" \
        -name "$name" -pidfile "$d/pid" -daemonize \
        -drive file="$DISK_DIR/$disk",format=raw,if=virtio,cache=none \
        -boot n \
        -netdev bridge,id=n0,br="$VM_BRIDGE" -device virtio-net,netdev=n0,mac="$mac" \
        -vnc "$LISTEN_IP:$disp"
    _record "$name" "$disp" "pxe-test" "$disk"
    _bridge_vnc "$name" "$disp"
    echo "$name"
}

# websockify one VNC display to a noVNC WebSocket (background, tracked by pidfile).
_bridge_vnc() {
    name="$1"; disp="$2"; d="$STATE_DIR/$name"
    vnc=$((5900 + disp)); ws=$((6080 + disp))
    websockify --daemon --run-once=false "$LISTEN_IP:$ws" "$LISTEN_IP:$vnc" \
        >/dev/null 2>&1 && echo "$ws" > "$d/ws" || true
}

_record() {
    name="$1"; disp="$2"; kind="$3"; disk="$4"; d="$STATE_DIR/$name"
    printf '{"name":"%s","display":%s,"vnc_port":%s,"ws_port":%s,"kind":"%s","disk":"%s"}\n' \
        "$name" "$disp" "$((5900 + disp))" "$((6080 + disp))" "$kind" "$disk" > "$d/meta"
}

# list — one JSON object per running VM (alive check via the pidfile).
list_vms() {
    printf '['
    first=1
    for d in "$STATE_DIR"/*/; do
        [ -f "$d/meta" ] || continue
        pid="$(cat "$d/pid" 2>/dev/null || echo 0)"
        kill -0 "$pid" 2>/dev/null || { rm -rf "$d"; continue; }
        [ "$first" = 1 ] || printf ','
        first=0
        cat "$d/meta"
    done
    printf ']\n'
}

# stop <name> — terminate the VM and its websockify bridge.
stop_vm() {
    name="$1"; d="$STATE_DIR/$name"
    [ -f "$d/pid" ] && kill "$(cat "$d/pid")" 2>/dev/null || true
    pkill -f "websockify.*:$( [ -f "$d/meta" ] && sed 's/.*"ws_port":\([0-9]*\).*/\1/' "$d/meta" )" 2>/dev/null || true
    rm -rf "$d"
    echo "$name"
}

cmd="${1:-}"; shift 2>/dev/null || true
case "$cmd" in
    start-install)  start_install "$@" ;;
    start-pxe-test) start_pxe_test "$@" ;;
    list)           list_vms ;;
    stop)           stop_vm "$@" ;;
    *) echo "usage: vm-control.sh {start-install <name> <iso> <disk> [gib] | start-pxe-test <name> <mac> <disk> [gib] | list | stop <name>}" >&2; exit 2 ;;
esac
