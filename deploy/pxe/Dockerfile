# The consolidated PXE-boot lab container: DHCP+TFTP (dnsmasq), an HTTP server for the PE squashfs +
# disk images + agent.deb, a nested-virt QEMU with a noVNC console, and the PE builder. It runs on `hal`
# against the second NIC (ens19) and needs host networking (DHCP/TFTP are L2) + /dev/kvm (nested QEMU).
#
# Build context is the REPO ROOT (like deploy/poller): the static agentic-mcpd built on the host is
# COPY'd in, because the build env can't reach proxy.golang.org. The proxy ARGs let apt reach the mirror.
FROM debian:trixie-slim

ARG http_proxy
ARG https_proxy
ARG no_proxy

RUN apt-get update && apt-get install -y --no-install-recommends \
        dnsmasq \
        nginx-light \
        squashfs-tools \
        debootstrap \
        qemu-system-x86 qemu-utils \
        websockify novnc \
        pxelinux syslinux-common grub-efi-amd64-bin \
        curl ca-certificates iproute2 kmod procps gettext-base \
        linux-image-amd64 \
        partclone zstd lvm2 jq fdisk parted \
    && rm -rf /var/lib/apt/lists/*

# The static agent, baked into the PE at build-pe time and served at the HTTP root as agent.deb.
COPY deploy-artifacts/agentic-mcpd /usr/bin/agentic-mcpd
COPY deploy-artifacts/agent.deb /srv/http/agent.deb

COPY deploy/pxe/entrypoint.sh /entrypoint.sh
COPY deploy/pxe/build-pe.sh /usr/local/sbin/build-pe.sh
COPY deploy/pxe/pe-init.sh /usr/local/sbin/pe-init.sh
COPY deploy/pxe/vm-control.sh /usr/local/bin/vm-control.sh
COPY deploy/pxe/import-image.sh /usr/local/bin/import-image.sh
RUN chmod +x /entrypoint.sh /usr/local/sbin/build-pe.sh /usr/local/sbin/pe-init.sh \
        /usr/local/bin/vm-control.sh /usr/local/bin/import-image.sh /usr/bin/agentic-mcpd

# QEMU's bridge helper (for the diskless PXE-test VM on the ens19 bridge) is ACL-gated: whitelist the
# bridge and give the helper the net cap. VM_BRIDGE defaults to br-ens19 (create it on the host, enslave
# ens19). The container also needs cap_add NET_ADMIN + /dev/kvm (compose, Block 6).
RUN mkdir -p /etc/qemu && echo "allow br-ens19" > /etc/qemu/bridge.conf \
    && setcap cap_net_admin+ep /usr/lib/qemu/qemu-bridge-helper 2>/dev/null || true

# HTTP root (nginx serves this): pe.squashfs, images/<id>/, agent.deb. TFTP root: kernel + initrd + loader.
RUN mkdir -p /srv/http/images /srv/tftp

ENTRYPOINT ["/entrypoint.sh"]
