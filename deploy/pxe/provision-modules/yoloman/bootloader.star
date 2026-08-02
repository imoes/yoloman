# yoloman.bootloader — install GRUB for the firmware the IMAGE was built for.
#
# A PROVISIONING-ONLY module (baked into the PE, not the builtin agent). Run INSIDE the restored
# root's chroot (so grub sees the target's disks + writes the target's /boot). Firmware-aware:
#   - bios  → grub-install --target=i386-pc <disk>  (MBR/boot-code to the disk).
#   - uefi  → grub-install --target=x86_64-efi --efi-directory=<esp> --bootloader-id=<id>
#             --removable --recheck  (grub-efi into the mounted ESP; --removable also writes the
#             firmware default EFI/BOOT/BOOTX64.EFI, so a machine with empty NVRAM still boots).
# Then update-grub to regenerate grub.cfg. This only works when the target's firmware MATCHES the
# image's — a BIOS image will not boot on UEFI and vice versa. Contract: {changed, msg, data}.

def main(ctx, params):
    firmware = params.get("firmware")
    if firmware not in ("bios", "uefi"):
        fail("firmware must be one of: bios, uefi")

    if firmware == "bios":
        disk = params.get("disk")
        if not disk:
            fail("disk is required for firmware=bios (e.g. /dev/sda)")
        argv = ["grub-install", "--target=i386-pc", disk]
    else:
        efi_dir = params.get("efi_directory", "/boot/efi")
        bl_id = params.get("bootloader_id", "debian")
        argv = ["grub-install", "--target=x86_64-efi", "--efi-directory=%s" % efi_dir,
                "--bootloader-id=%s" % bl_id, "--removable", "--recheck"]

    res = ctx.run(argv, mutates=True)
    if res.rc != 0:
        fail("grub-install (%s) failed: %s" % (firmware, res.stderr))
    cfg = ctx.run(["update-grub"], mutates=True)
    if cfg.rc != 0:
        fail("update-grub failed: %s" % cfg.stderr)
    return {
        "changed": True,
        "msg": "installed %s bootloader and regenerated grub config" % firmware,
        "data": {"firmware": firmware},
    }
