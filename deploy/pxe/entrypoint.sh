#!/bin/sh
# PXE-boot lab entrypoint. Env-driven, first-boot idempotent. Serves DHCP (proxy|full) + TFTP via
# dnsmasq and the PE squashfs + disk images + agent.deb over HTTP (nginx). QEMU is launched on demand
# by Bossman (docker exec / control), not here. See docs/pxe-baremetal-imaging.md.
set -eu

PXE_INTERFACE="${PXE_INTERFACE:-ens19}"
PXE_LISTEN_IP="${PXE_LISTEN_IP:-192.0.2.130}"
DHCP_MODE="${DHCP_MODE:-proxy}"                 # proxy | full
DHCP_RANGE="${DHCP_RANGE:-192.0.2.150,192.0.2.200,12h}"   # full mode only
DHCP_ROUTER="${DHCP_ROUTER:-$PXE_LISTEN_IP}"    # full mode only
NETBOOT_SECRET="${NETBOOT_SECRET:-}"
BOSSMAN_URL="${BOSSMAN_URL:-http://bossman:8000}"
TFTP_ROOT="${TFTP_ROOT:-/srv/tftp}"
HTTP_ROOT="${HTTP_ROOT:-/srv/http}"

if [ -z "$NETBOOT_SECRET" ]; then
    echo "pxe: NETBOOT_SECRET is empty — refusing to start (the same secret Bossman validates on /netboot/checkin)" >&2
    exit 1
fi

# ── 1. Build the PE once (debootstrap + mksquashfs + kernel/initrd) if it is not there yet. ──────────
if [ ! -f "$HTTP_ROOT/pe.squashfs" ] || [ ! -f "$TFTP_ROOT/pe-kernel" ]; then
    echo "pxe: building the preinstallation environment (first boot)…"
    build-pe.sh
fi

# ── 2. The kernel command line every target gets: RAM-boot the squashfs (live-boot fetch=) and hand it
#       the secret + Bossman URL so pe-init can check in. `ip=dhcp` brings the NIC up first. ───────────
APPEND="boot=live components fetch=http://${PXE_LISTEN_IP}/pe.squashfs ip=dhcp \
netboot_secret=${NETBOOT_SECRET} bossman_url=${BOSSMAN_URL}"

# BIOS PXELINUX menu.
mkdir -p "$TFTP_ROOT/pxelinux.cfg"
cat > "$TFTP_ROOT/pxelinux.cfg/default" <<EOF
default pe
label pe
    kernel pe-kernel
    append initrd=pe-initrd ${APPEND}
EOF
# Loaders in the TFTP root (BIOS pxelinux + its libs; UEFI grub is templated by build-pe).
cp -f /usr/lib/PXELINUX/pxelinux.0 "$TFTP_ROOT/" 2>/dev/null || true
cp -f /usr/lib/syslinux/modules/bios/ldlinux.c32 "$TFTP_ROOT/" 2>/dev/null || true

# ── 3. dnsmasq: DHCP (proxy or full) + TFTP. Proxy mode augments an existing DHCP server; full mode
#       hands out addresses itself. Either way it points BIOS at pxelinux.0 and UEFI at grubx64.efi. ──
DNSMASQ_CONF=/etc/dnsmasq.d/pxe.conf
{
    echo "interface=${PXE_INTERFACE}"
    echo "bind-interfaces"
    echo "enable-tftp"
    echo "tftp-root=${TFTP_ROOT}"
    if [ "$DHCP_MODE" = "full" ]; then
        echo "dhcp-range=${DHCP_RANGE}"
        echo "dhcp-option=option:router,${DHCP_ROUTER}"
    else
        # proxy DHCP: no address handout, just PXE boot info alongside the network's own DHCP.
        echo "dhcp-range=${PXE_LISTEN_IP},proxy"
    fi
    # BIOS vs UEFI boot file (dnsmasq matches the client arch tag).
    echo "dhcp-match=set:bios,option:client-arch,0"
    echo "dhcp-boot=tag:bios,pxelinux.0"
    echo "dhcp-match=set:efi64,option:client-arch,7"
    echo "dhcp-boot=tag:efi64,grubx64.efi"
    echo "pxe-service=x86PC,\"Bossman PXE install\",pxelinux"
} > "$DNSMASQ_CONF"

# ── 4. nginx serves the HTTP root (pe.squashfs, images/<id>/, agent.deb). ────────────────────────────
cat > /etc/nginx/sites-available/default <<EOF
server {
    listen ${PXE_LISTEN_IP}:80 default_server;
    root ${HTTP_ROOT};
    autoindex on;
    location / { }
}
EOF

echo "pxe: dnsmasq(${DHCP_MODE}) + TFTP on ${PXE_INTERFACE}/${PXE_LISTEN_IP}, HTTP root ${HTTP_ROOT}, bossman ${BOSSMAN_URL}"
nginx
# websockify→noVNC is started per-VM by the QEMU control path; leave the static novnc assets served by nginx.
exec dnsmasq --keep-in-foreground --log-facility=- --conf-file="$DNSMASQ_CONF"
