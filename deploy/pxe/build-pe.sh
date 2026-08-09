#!/bin/sh
# Build the RAM preinstallation environment: a Debian-minimal rootfs with the restore toolchain and the
# pe-init provisioner, packed as a squashfs (RAM-booted via live-boot's fetch=), plus its kernel + initrd
# for TFTP. Run once by the entrypoint when pe.squashfs is missing. Needs the Debian mirror (via proxy).
set -eu

PE_ROOT="${PE_ROOT:-/pe-root}"
HTTP_ROOT="${HTTP_ROOT:-/srv/http}"
TFTP_ROOT="${TFTP_ROOT:-/srv/tftp}"
SUITE="${PE_SUITE:-trixie}"
MIRROR="${PE_MIRROR:-http://deb.debian.org/debian}"

# Fast path: /pe-root is a persistent volume. If the rootfs was already fully built (kernel present),
# reuse it and only re-pack the squashfs — a container recreate loses pe.squashfs (container layer) but
# NOT the rootfs, so this turns a ~5-min rebuild into a ~30s re-pack.
if ls "$PE_ROOT"/boot/vmlinuz-* >/dev/null 2>&1; then
    echo "build-pe: reusing existing rootfs in ${PE_ROOT} (skipping debootstrap)"
else
    echo "build-pe: debootstrap ${SUITE} into ${PE_ROOT}…"
    # A mounted volume — clear its CONTENTS, never rm the mountpoint itself ("Device or resource busy").
    mkdir -p "$PE_ROOT"
    find "$PE_ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    debootstrap --variant=minbase --include=ca-certificates "$SUITE" "$PE_ROOT" "$MIRROR"
fi

# The toolchain the restore steps run IN THE PE (init, live-boot, the kernel, and the tools the returned
# steps invoke: sfdisk/wipefs, lvm, partclone, resize2fs/xfs_growfs, curl/zstd, grub for build-pe's own
# netdir). ALWAYS run (apt is idempotent), so adding a package here takes effect on the next re-pack
# without wiping the persistent rootfs.
chroot "$PE_ROOT" /bin/sh -eu <<'CHROOT'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    systemd-sysv udev dbus \
    live-boot live-boot-initramfs-tools \
    linux-image-amd64 \
    partclone lvm2 e2fsprogs xfsprogs dosfstools fdisk \
    grub-pc-bin grub-efi-amd64-bin \
    curl jq gdisk util-linux zstd ca-certificates
apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOT

# The provisioner + its oneshot unit: run pe-init after the network is up.
cp -f /usr/local/sbin/pe-init.sh "$PE_ROOT/usr/local/sbin/pe-init.sh"
chmod +x "$PE_ROOT/usr/local/sbin/pe-init.sh"
# The agent binary itself, so the restore can drive MODULES offline in the target chroot
# (`agentic-mcpd run-module …` — see services/offline_enroll.network_steps). Copied from the container's
# /usr/bin (baked by the Dockerfile from deploy-artifacts/agentic-mcpd).
cp -f /usr/bin/agentic-mcpd "$PE_ROOT/usr/bin/agentic-mcpd" 2>/dev/null || true
chmod +x "$PE_ROOT/usr/bin/agentic-mcpd" 2>/dev/null || true
# The provisioning-only modules (yoloman.disk_partition / partclone_restore / bootloader / initramfs /
# machine_identity): baked into the PE, NOT the builtin agent — they are one-shot deploy ops. The restore
# runs them via `agentic-mcpd run-module <name> --modules-dir <this dir>` (PE-level ops directly, chroot-level
# ops after staging this tree into the target). Copied from the container (Dockerfile COPY).
PROV_MODULES="/usr/share/agentic-provision-modules"
if [ -d "$PROV_MODULES" ]; then
    rm -rf "${PE_ROOT}${PROV_MODULES}"
    mkdir -p "${PE_ROOT}$(dirname "$PROV_MODULES")"
    cp -a "$PROV_MODULES" "${PE_ROOT}${PROV_MODULES}"
    echo "build-pe: baked provisioning modules into ${PE_ROOT}${PROV_MODULES}"
fi
mkdir -p "$PE_ROOT/etc/systemd/system"
cat > "$PE_ROOT/etc/systemd/system/pe-provision.service" <<'UNIT'
[Unit]
Description=Bossman PXE provision (check in, restore, enrol)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/pe-init.sh
StandardOutput=journal+console
StandardError=journal+console
[Install]
WantedBy=multi-user.target
UNIT
chroot "$PE_ROOT" systemctl enable pe-provision.service

# Rebuild the initramfs so live-boot's hooks are in it, then harvest kernel + initrd for TFTP.
chroot "$PE_ROOT" update-initramfs -u
mkdir -p "$TFTP_ROOT"
cp -f "$PE_ROOT"/boot/vmlinuz-* "$TFTP_ROOT/pe-kernel"
cp -f "$PE_ROOT"/boot/initrd.img-* "$TFTP_ROOT/pe-initrd"

# UEFI netboot loader. grub-mknetdir builds core.efi + its module tree; it needs the grub tools + modules
# from inside the PE, so run it in the chroot writing to a temp dir, then copy the tree onto the real TFTP
# root. dnsmasq points UEFI clients at grub/x86_64-efi/core.efi; the entrypoint writes grub/grub.cfg (the
# same append line as PXELINUX, with the WebUI netboot secret).
rm -rf "$PE_ROOT/tmp/netboot"
if chroot "$PE_ROOT" grub-mknetdir --net-directory=/tmp/netboot --subdir=/grub >/dev/null 2>&1; then
    rm -rf "$TFTP_ROOT/grub"
    cp -a "$PE_ROOT/tmp/netboot/grub" "$TFTP_ROOT/grub"
    echo "build-pe: UEFI grub netboot loader at ${TFTP_ROOT}/grub/x86_64-efi/core.efi"
else
    echo "build-pe: WARNING grub-mknetdir failed — UEFI PXE boot will not work" >&2
fi

# Pack the rootfs as the squashfs live-boot fetches into RAM.
echo "build-pe: mksquashfs → ${HTTP_ROOT}/pe.squashfs…"
mkdir -p "$HTTP_ROOT/live"
mksquashfs "$PE_ROOT" "$HTTP_ROOT/pe.squashfs" -noappend -comp zstd -e boot
echo "build-pe: done ($(du -h "$HTTP_ROOT/pe.squashfs" | cut -f1) squashfs)"
