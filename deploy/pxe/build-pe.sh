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
    echo "build-pe: reusing existing rootfs in ${PE_ROOT} (skipping debootstrap + apt)"
else
    echo "build-pe: debootstrap ${SUITE} into ${PE_ROOT}…"
    # A mounted volume — clear its CONTENTS, never rm the mountpoint itself ("Device or resource busy").
    mkdir -p "$PE_ROOT"
    find "$PE_ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    debootstrap --variant=minbase --include=ca-certificates "$SUITE" "$PE_ROOT" "$MIRROR"

    # The toolchain the returned restore steps need, plus live-boot (RAM boot) and the kernel.
    chroot "$PE_ROOT" /bin/sh -eu <<'CHROOT'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    live-boot live-boot-initramfs-tools \
    linux-image-amd64 \
    partclone lvm2 e2fsprogs xfsprogs dosfstools \
    grub-pc-bin grub-efi-amd64-bin \
    curl jq gdisk util-linux zstd ca-certificates
apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOT
fi

# The provisioner + its oneshot unit: run pe-init after the network is up.
cp -f /usr/local/sbin/pe-init.sh "$PE_ROOT/usr/local/sbin/pe-init.sh"
chmod +x "$PE_ROOT/usr/local/sbin/pe-init.sh"
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

# UEFI loader + grub.cfg (mirrors the PXELINUX append the entrypoint writes).
cp -f "$PE_ROOT"/usr/lib/grub/x86_64-efi/monolithic/grubnetx64.efi.signed "$TFTP_ROOT/grubx64.efi" 2>/dev/null \
    || chroot "$PE_ROOT" grub-mknetdir --net-directory="$TFTP_ROOT" --subdir=/ 2>/dev/null || true

# Pack the rootfs as the squashfs live-boot fetches into RAM.
echo "build-pe: mksquashfs → ${HTTP_ROOT}/pe.squashfs…"
mkdir -p "$HTTP_ROOT/live"
mksquashfs "$PE_ROOT" "$HTTP_ROOT/pe.squashfs" -noappend -comp zstd -e boot
echo "build-pe: done ($(du -h "$HTTP_ROOT/pe.squashfs" | cut -f1) squashfs)"
