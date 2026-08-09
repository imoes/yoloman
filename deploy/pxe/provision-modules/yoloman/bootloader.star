def main(ctx, params):
    firmware = params["firmware"]
    disk = params.get("disk")
    efi_directory = params.get("efi_directory", "/boot/efi")
    bootloader_id = params.get("bootloader_id", "debian")

    if firmware == "bios":
        if disk == None:
            fail("disk is required when firmware is bios")
        install = ctx.run(["grub-install", "--target=i386-pc", disk], mutates=True)
    elif firmware == "uefi":
        install = ctx.run([
            "grub-install",
            "--target=x86_64-efi",
            "--efi-directory=" + efi_directory,
            "--bootloader-id=" + bootloader_id,
            "--removable",
            "--recheck"
        ], mutates=True)
    else:
        fail("unsupported firmware: " + str(firmware))

    if install.skipped:
        return {"changed": True, "msg": "would install grub with firmware " + firmware, "data": {"firmware": firmware}}

    if install.rc != 0:
        fail("grub-install failed for firmware " + firmware + ": " + install.stderr)

    update = ctx.run(["update-grub"], mutates=True)
    if update.skipped:
        return {"changed": True, "msg": "would run update-grub for firmware " + firmware, "data": {"firmware": firmware}}

    if update.rc != 0:
        fail("update-grub failed for firmware " + firmware + ": " + update.stderr)

    return {"changed": True, "msg": "installed grub with firmware " + firmware, "data": {"firmware": firmware}}
