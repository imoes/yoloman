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
# HTTP port for pe.squashfs + images + agent.deb. Host-network means this binds the HOST's port on
# PXE_LISTEN_IP, so it must be free there — hal already runs something on :80, so the override sets 8080.
# Targets fetch the PE + images at this port, so BOSSMAN_IMAGE_BASE_URL must match it.
PXE_HTTP_PORT="${PXE_HTTP_PORT:-80}"
# Node agent: makes this lab container a MANAGED HOST so Bossman can apply Features/config to it — e.g.
# the dnsmasq DHCP config-template whose range is edited in the WebUI. Reachability (host network on
# ens19): ENROLL_URL and PXE_AGENT_ADDRESS must be routable from the Bossman container. Set PXE_RUN_AGENT=0
# to skip (config falls back to the entrypoint-written dnsmasq conf).
PXE_RUN_AGENT="${PXE_RUN_AGENT:-1}"
ENROLL_URL="${ENROLL_URL:-$BOSSMAN_URL}"
PXE_AGENT_NAME="${PXE_AGENT_NAME:-pxe-lab}"
PXE_AGENT_LISTEN="${PXE_AGENT_LISTEN:-0.0.0.0:8051}"
PXE_AGENT_ADDRESS="${PXE_AGENT_ADDRESS:-${PXE_LISTEN_IP}:8051}"

# The netboot secret is NOT configured here anymore: it is set + enabled/disabled in the WebUI (Bossman
# SystemSettings), and this container FETCHES the effective value from GET /api/v1/netboot/config using
# its own agent token. So the WebUI is the single source of truth — no env/override secret to keep in
# sync. Until a secret is set + netboot enabled there, no secret is stamped and DHCP stays off.

# ── Node-agent bootstrap (mirrors deploy/poller/entrypoint.sh): first-boot config.yaml with a fresh
#    token + self-signed TLS, enroll with Bossman, then run the daemon. write:true so Bossman can PUSH
#    the dnsmasq config-template. Idempotent — an existing config.yaml is reused. ─────────────────────
start_agent() {
    conf=/etc/agentic-mcp/config.yaml
    mkdir -p /etc/agentic-mcp/trusted /var/lib/agentic-mcp
    if [ ! -f "$conf" ]; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
            -keyout /etc/agentic-mcp/tls.key -out /etc/agentic-mcp/tls.crt \
            -days 3650 -subj "/CN=${PXE_AGENT_NAME}" >/dev/null 2>&1
        token="$(agentic-mcpd --generate-token)"
        cat > "$conf" <<EOF
listen: "${PXE_AGENT_LISTEN}"
token: "${token}"
write: true
tls:
  enabled: true
  cert_file: /etc/agentic-mcp/tls.crt
  key_file: /etc/agentic-mcp/tls.key
  trusted_client_keys:
    - name: enroller
      public_key_path: /etc/agentic-mcp/trusted/enroller.pub.pem
ebpf:
  enabled: false
db:
  driver: sqlite
  path: /var/lib/agentic-mcp/agentic-mcp.db
pam:
  enabled: false
ui:
  enabled: false
EOF
        chmod 0600 "$conf"
    fi
    i=0
    while [ "$i" -lt 40 ]; do
        if agentic-mcpd register --enroll-url "$ENROLL_URL" \
                --name "$PXE_AGENT_NAME" --address "$PXE_AGENT_ADDRESS" --config "$conf"; then
            echo "pxe: agent enrolled as ${PXE_AGENT_NAME} with ${ENROLL_URL}"
            break
        fi
        i=$((i + 1)); echo "pxe: agent enroll attempt $i failed, retrying in 3s…"; sleep 3
    done
    exec agentic-mcpd --config "$conf"
}
if [ "$PXE_RUN_AGENT" = "1" ]; then
    ( start_agent ) &
    echo "pxe: node agent starting in background (managed-host mode)"
fi

# ── 1. Build the PE once (debootstrap + mksquashfs + kernel/initrd) if it is not there yet. ──────────
if [ ! -f "$HTTP_ROOT/pe.squashfs" ] || [ ! -f "$TFTP_ROOT/pe-kernel" ]; then
    echo "pxe: building the preinstallation environment (first boot)…"
    build-pe.sh
fi

# ── 2. The kernel command line every target gets: RAM-boot the squashfs (live-boot fetch=) and hand it
#       the WebUI-set secret + Bossman URL so pe-init can check in. Written by stamp_cmdline() from the
#       reconcile loop whenever the effective secret changes — not statically here. ─────────────────────
mkdir -p "$TFTP_ROOT/pxelinux.cfg"
stamp_cmdline() {   # $1 = netboot secret (may be empty when netboot is disabled/unset)
    append="boot=live components fetch=http://${PXE_LISTEN_IP}:${PXE_HTTP_PORT}/pe.squashfs ip=dhcp \
netboot_secret=$1 bossman_url=${BOSSMAN_URL}"
    # BIOS (PXELINUX)
    cat > "$TFTP_ROOT/pxelinux.cfg/default" <<EOF
default pe
label pe
    kernel pe-kernel
    append initrd=pe-initrd ${append}
EOF
    # UEFI (GRUB) — same append, loaded by grub/x86_64-efi/core.efi (built by build-pe). grub's \$root is
    # the TFTP server, so /pe-kernel and /pe-initrd resolve against the TFTP root.
    mkdir -p "$TFTP_ROOT/grub"
    cat > "$TFTP_ROOT/grub/grub.cfg" <<EOF
set timeout=0
menuentry "Bossman PXE install" {
    linux /pe-kernel ${append}
    initrd /pe-initrd
}
EOF
}
stamp_cmdline ""   # start with no secret; the loop stamps the real one once the WebUI has it
# Loaders in the TFTP root (BIOS pxelinux + its libs; UEFI grub is templated by build-pe).
cp -f /usr/lib/PXELINUX/pxelinux.0 "$TFTP_ROOT/" 2>/dev/null || true
cp -f /usr/lib/syslinux/modules/bios/ldlinux.c32 "$TFTP_ROOT/" 2>/dev/null || true

# ── 3. dnsmasq conf writer: TFTP is ALWAYS served; DHCP is written only when asked (arg = on). Proxy
#       mode augments an existing DHCP server; full mode hands out addresses itself. Either way it points
#       BIOS at pxelinux.0 and UEFI at grubx64.efi. ──────────────────────────────────────────────────
DNSMASQ_CONF=/etc/dnsmasq.d/pxe.conf
write_dnsmasq_conf() {   # $1 = on|off
    {
        echo "interface=${PXE_INTERFACE}"
        echo "bind-interfaces"
        echo "enable-tftp"
        echo "tftp-root=${TFTP_ROOT}"
        if [ "$1" = "on" ]; then
            if [ "$DHCP_MODE" = "full" ]; then
                echo "dhcp-range=${DHCP_RANGE}"
                echo "dhcp-option=option:router,${DHCP_ROUTER}"
            else
                # proxy DHCP: no address handout, just PXE boot info alongside the network's own DHCP.
                echo "dhcp-range=${PXE_LISTEN_IP},proxy"
            fi
            # Serve BIOS vs UEFI automatically off the client's DHCP arch option (opt 93): the machine
            # tells us what it is, so both boot the same lab with no manual choice.
            echo "dhcp-match=set:bios,option:client-arch,0"      # legacy BIOS PC
            echo "dhcp-boot=tag:bios,pxelinux.0"
            echo "dhcp-match=set:efi64,option:client-arch,7"     # EFI BC (x86-64)
            echo "dhcp-match=set:efi64,option:client-arch,9"     # EFI x86-64 (some firmwares send 9)
            echo "dhcp-boot=tag:efi64,grub/x86_64-efi/core.efi"
            echo "pxe-service=x86PC,\"Bossman PXE install\",pxelinux"
        fi
    } > "$DNSMASQ_CONF"
}
restart_dnsmasq() {
    pkill -x dnsmasq 2>/dev/null || true
    # Wait for the old dnsmasq to actually exit and release the bound socket before starting a new one —
    # otherwise the new one hits "Address already in use", which under set -e would kill the container.
    i=0; while pgrep -x dnsmasq >/dev/null 2>&1 && [ "$i" -lt 25 ]; do sleep 0.2; i=$((i + 1)); done
    i=0; while [ "$i" -lt 10 ]; do
        dnsmasq --log-facility=- --conf-file="$DNSMASQ_CONF" && return 0
        sleep 0.5; i=$((i + 1))
    done
    echo "pxe: WARNING dnsmasq did not (re)start after retries" >&2
    return 0   # never let a transient bind race take the whole container down
}

# ── 4. nginx serves the HTTP root (pe.squashfs, images/<id>/, agent.deb). ────────────────────────────
cat > /etc/nginx/sites-available/default <<EOF
server {
    listen ${PXE_LISTEN_IP}:${PXE_HTTP_PORT} default_server;
    root ${HTTP_ROOT};
    autoindex on;
    location / { }
}
EOF
nginx

# ── 5. Start DHCP OFF (TFTP only), then reconcile against Bossman via GET /netboot/config (authenticated
#       by this container's own agent token): it returns {enabled, secret, dhcp}. The WebUI is the single
#       source — we stamp the secret onto the PXE cmdline when it changes, and serve DHCP ONLY when a
#       restore job is pending (`dhcp:true`), so there is never a standing DHCP/PXE server otherwise.
#       BOSSMAN_URL must be reachable from this container (host network). ──────────────────────────────
agent_token() { sed -n 's/^token:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' /etc/agentic-mcp/config.yaml 2>/dev/null | head -1; }
state=off
last_secret="__unset__"
write_dnsmasq_conf off
restart_dnsmasq
echo "pxe: TFTP on ${PXE_INTERFACE}/${PXE_LISTEN_IP}, HTTP root ${HTTP_ROOT}; DHCP + secret gated via ${BOSSMAN_URL}/netboot/config"
while true; do
    tok="$(agent_token)"
    resp=""
    [ -n "$tok" ] && resp="$(curl -fsS -m 5 -H "Authorization: Bearer ${tok}" "${BOSSMAN_URL}/api/v1/netboot/config" 2>/dev/null || true)"
    if [ -n "$resp" ]; then
        secret="$(printf '%s' "$resp" | jq -r '.secret // ""' 2>/dev/null || echo "")"
        case "$resp" in *'"dhcp":true'*|*'"dhcp": true'*) want=on ;; *) want=off ;; esac
        # Re-stamp the PXE cmdline only when the effective secret actually changed.
        if [ "$secret" != "$last_secret" ]; then
            stamp_cmdline "$secret"; last_secret="$secret"
            echo "pxe: netboot secret updated from WebUI ($( [ -n "$secret" ] && echo set || echo cleared ))"
        fi
    else
        want="$state"   # Bossman/token not ready → hold current state rather than flap
    fi
    if [ "$want" != "$state" ]; then
        echo "pxe: DHCP ${want}"
        write_dnsmasq_conf "$want"
        restart_dnsmasq
        state="$want"
    fi
    sleep "${DHCP_POLL_SECONDS:-10}"
done
