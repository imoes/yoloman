def main(ctx, params):
    dev = params["dev"]
    state = params.get("state", "present")
    fstype = params.get("fstype")
    opts = params.get("opts")
    force = params.get("force", False)
    resizefs = params.get("resizefs", False)
    uuid = params.get("uuid")

    # Parse opts string into list
    mkfs_opts = []
    if opts != None:
        mkfs_opts = opts.split()

    # Friendly name mapping
    friendly_names = {
        "lvm": "LVM2_member",
    }

    # Filesystem class mapping
    FILESYSTEMS = {
        "ext2": "Ext2",
        "ext3": "Ext3",
        "ext4": "Ext4",
        "ext4dev": "Ext4",
        "f2fs": "F2fs",
        "reiserfs": "Reiserfs",
        "xfs": "XFS",
        "btrfs": "Btrfs",
        "vfat": "VFAT",
        "ocfs2": "Ocfs2",
        "LVM2_member": "LVM",
        "swap": "Swap",
        "ufs": "UFS",
    }

    # Check device exists
    if not ctx.file_exists(dev):
        msg = "Device " + dev + " not found."
        if state == "present":
            fail(msg)
        else:
            return {"changed": False, "msg": msg}

    # Probe existing filesystem type using blkid
    res = ctx.run(["blkid", "-c", "/dev/null", "-o", "value", "-s", "TYPE", dev])
    fs = res.stdout.strip() if res.rc == 0 else ""
    # Fallback for FreeBSD
    if not fs and ctx.facts().get("os_family") == "FreeBSD":
        res = ctx.run(["fstyp", dev])
        fs = res.stdout.strip() if res.rc == 0 else ""

    changed = False

    if state == "present":
        if fstype == None:
            fail("fstype is required when state=present")
        if fstype in friendly_names:
            fstype = friendly_names[fstype]
        if fstype not in FILESYSTEMS:
            fail("module does not support this filesystem (" + fstype + ") yet.")

        # Check if same fs type already exists
        same_fs = fs and FILESYSTEMS.get(fs) == FILESYSTEMS[fstype]

        # If same fs, not resize, not uuid, not force -> no change
        if same_fs and not resizefs and not uuid and not force:
            return {"changed": False, "msg": "filesystem " + fstype + " already exists on " + dev}

        if same_fs:
            if resizefs:
                # Check if resize is supported
                if fstype not in ["btrfs", "ext2", "ext3", "ext4", "ext4dev", "f2fs", "lvm", "xfs", "ufs", "vfat"]:
                    fail("module does not support resizing " + fstype + " filesystem yet.")
                if fstype == "xfs":
                    # For xfs, we need mountpoint
                    res = ctx.run(["findmnt", "--mtab", "--noheadings", "--output", "TARGET", "--source", dev])
                    mountpoint = res.stdout.strip().split('\n')[0] if res.rc == 0 else ""
                    if not mountpoint:
                        fail("xfs needs to be mounted for resize operations")
                    target = mountpoint
                elif fstype == "btrfs":
                    res = ctx.run(["findmnt", "--mtab", "--noheadings", "--output", "TARGET", "--source", dev])
                    mountpoint = res.stdout.strip().split('\n')[0] if res.rc == 0 else ""
                    if not mountpoint:
                        fail("btrfs needs to be mounted for resize operations")
                    target = mountpoint
                else:
                    target = dev

                if fstype == "vfat":
                    # fatresize needs the device directly
                    res = ctx.run(["fatresize", "--info", target])
                    # Parse current size vs max size (simplified)
                    # In check_mode, fatresize shows current and max size
                    if ctx.check_mode:
                        return {"changed": True, "msg": "would resize " + fstype + " filesystem on " + dev}
                    res = ctx.run(["fatresize", "-s", "max", target])
                    if res.rc != 0:
                        fail("failed to resize fat filesystem: " + res.stderr)
                elif fstype == "btrfs":
                    if ctx.check_mode:
                        return {"changed": True, "msg": "would resize " + fstype + " filesystem on " + dev}
                    res = ctx.run(["btrfs", "filesystem", "resize", "max", target])
                    if res.rc != 0:
                        fail("failed to resize btrfs filesystem: " + res.stderr)
                elif fstype in ["ext2", "ext3", "ext4", "ext4dev"]:
                    if ctx.check_mode:
                        return {"changed": True, "msg": "would resize " + fstype + " filesystem on " + dev}
                    # resize2fs refuses to grow a filesystem that has not just been checked
                    # ("Please run 'e2fsck -f' first"), so force a check first (-f -y = force + assume-yes).
                    # This is unavoidable right after a partclone restore, where the fs was never fsck'd.
                    chk = ctx.run(["e2fsck", "-f", "-y", target], mutates=True, ok_codes=[0, 1, 2])
                    if not chk.skipped and chk.rc > 2:
                        fail("e2fsck before resize failed: " + chk.stderr)
                    res = ctx.run(["resize2fs", target])
                    if res.rc != 0:
                        fail("failed to resize ext filesystem: " + res.stderr)
                elif fstype == "xfs":
                    if ctx.check_mode:
                        return {"changed": True, "msg": "would resize " + fstype + " filesystem on " + dev}
                    res = ctx.run(["xfs_growfs", target])
                    if res.rc != 0:
                        fail("failed to resize xfs filesystem: " + res.stderr)
                elif fstype == "ufs":
                    if ctx.check_mode:
                        return {"changed": True, "msg": "would resize " + fstype + " filesystem on " + dev}
                    res = ctx.run(["growfs", "-y", target])
                    if res.rc != 0:
                        fail("failed to resize ufs filesystem: " + res.stderr)
                elif fstype == "f2fs":
                    if ctx.check_mode:
                        return {"changed": True, "msg": "would resize " + fstype + " filesystem on " + dev}
                    res = ctx.run(["resize.f2fs", target])
                    if res.rc != 0:
                        fail("failed to resize f2fs filesystem: " + res.stderr)
                elif fstype == "lvm":
                    if ctx.check_mode:
                        return {"changed": True, "msg": "would resize " + fstype + " filesystem on " + dev}
                    res = ctx.run(["pvresize", target])
                    if res.rc != 0:
                        fail("failed to resize lvm filesystem: " + res.stderr)
                changed = True
                return {"changed": changed, "msg": "resized " + fstype + " filesystem on " + dev}

            elif uuid:
                # Check if uuid change is supported
                supported_uuid_fs = ["ext2", "ext3", "ext4", "ext4dev", "lvm", "xfs"]
                if fstype not in supported_uuid_fs:
                    fail("module does not support UUID option for this filesystem (" + fstype + ") yet.")

                # Generate new UUID if needed
                new_uuid = uuid
                if uuid == "generate":
                    if fstype == "xfs":
                        res = ctx.run(["xfs_admin", "-U", "generate", dev])
                        if res.rc != 0:
                            fail("failed to generate xfs UUID: " + res.stderr)
                        new_uuid = res.stdout.strip()
                    else:
                        # ext* and lvm use tune2fs/pvchange with random or generate
                        res = ctx.run(["uuidgen"])
                        new_uuid = res.stdout.strip() if res.rc == 0 else "random"
                elif uuid == "random":
                    if fstype == "xfs":
                        res = ctx.run(["xfs_admin", "-U", "clear", dev])
                        if res.rc != 0:
                            fail("failed to set xfs UUID to random: " + res.stderr)
                        res = ctx.run(["xfs_admin", "-U", "generate", dev])
                        if res.rc != 0:
                            fail("failed to set xfs UUID to random: " + res.stderr)
                    else:
                        res = ctx.run(["uuidgen"])
                        new_uuid = res.stdout.strip() if res.rc == 0 else "random"

                if ctx.check_mode:
                    return {"changed": True, "msg": "would change " + fstype + " UUID on " + dev}

                # Apply UUID change
                if fstype == "xfs":
                    res = ctx.run(["xfs_admin", "-U", new_uuid, dev])
                    if res.rc != 0:
                        fail("failed to set xfs UUID: " + res.stderr)
                elif fstype == "lvm":
                    if new_uuid == "random":
                        res = ctx.run(["pvchange", "-u", dev])
                    else:
                        fail("LVM UUID change only supports 'random' value")
                    if res.rc != 0:
                        fail("failed to change LVM UUID: " + res.stderr)
                else:  # ext2/3/4/4dev
                    res = ctx.run(["tune2fs", "-U", new_uuid, dev])
                    if res.rc != 0:
                        fail("failed to set ext filesystem UUID: " + res.stderr)

                changed = True
                return {"changed": changed, "msg": "changed " + fstype + " UUID on " + dev}

        elif fs and not force:
            fail("'" + dev + "' is already used as " + fs + ", use force=true to overwrite")

        # Create filesystem
        if ctx.check_mode:
            return {"changed": True, "msg": "would create " + fstype + " filesystem on " + dev}

        mkfs_cmd = None
        mkfs_force_flags = []

        if fstype == "ext2":
            mkfs_cmd = ["mkfs.ext2", "-F"]
        elif fstype == "ext3":
            mkfs_cmd = ["mkfs.ext3", "-F"]
        elif fstype == "ext4":
            mkfs_cmd = ["mkfs.ext4", "-F"]
        elif fstype == "xfs":
            mkfs_cmd = ["mkfs.xfs", "-f"]
        elif fstype == "vfat":
            if ctx.facts().get("os_family") == "FreeBSD":
                mkfs_cmd = ["newfs_msdos"]
            else:
                mkfs_cmd = ["mkfs.vfat"]
        elif fstype == "btrfs":
            mkfs_cmd = ["mkfs.btrfs", "-f"]
        elif fstype == "reiserfs":
            mkfs_cmd = ["mkfs.reiserfs", "-q"]
        elif fstype == "ocfs2":
            mkfs_cmd = ["mkfs.ocfs2", "-Fx"]
        elif fstype == "f2fs":
            mkfs_cmd = ["mkfs.f2fs"]
        elif fstype == "lvm":
            mkfs_cmd = ["pvcreate", "-f"]
        elif fstype == "swap":
            mkfs_cmd = ["mkswap", "-f"]
        elif fstype == "ufs":
            mkfs_cmd = ["newfs"]
        else:
            fail("Unsupported filesystem: " + fstype)

        if mkfs_cmd == None:
            fail("mkfs command not defined for " + fstype)

        cmd = mkfs_cmd + mkfs_opts + [dev]

        # Handle UUID for mkfs commands that support it directly
        if uuid and fstype in ["ext2", "ext3", "ext4", "ext4dev", "xfs"]:
            if uuid == "generate":
                res = ctx.run(["uuidgen"])
                uuid = res.stdout.strip() if res.rc == 0 else "random"
            elif uuid == "random":
                res = ctx.run(["uuidgen"])
                uuid = res.stdout.strip() if res.rc == 0 else "random"
            if fstype in ["ext2", "ext3", "ext4", "ext4dev"]:
                cmd = ["mkfs." + fstype, "-F", "-U", uuid] + mkfs_opts + [dev]
            elif fstype == "xfs":
                cmd = ["mkfs.xfs", "-f", "-U", uuid] + mkfs_opts + [dev]

        # Special handling for LVM
        if fstype == "lvm" and uuid:
            if uuid == "random":
                cmd = ["pvcreate", "-f", "--norestorefile", "--uuid", "generate", dev]
            elif uuid == "generate":
                cmd = ["pvcreate", "-f", "--norestorefile", "--uuid", "generate", dev]
            else:
                cmd = ["pvcreate", "-f", "--norestorefile", "--uuid", uuid, dev]

        res = ctx.run(cmd)
        if res.rc != 0:
            fail("failed to create " + fstype + " filesystem: " + res.stderr)
        changed = True

    elif state == "absent":
        if fs:
            if ctx.check_mode:
                return {"changed": True, "msg": "would wipe filesystem signatures from " + dev}
            # Wipe filesystem signatures using wipefs
            res = ctx.run(["wipefs", "--all", dev])
            if res.rc != 0:
                # Fallback: try dd to first sectors if wipefs fails
                res = ctx.run(["dd", "if=/dev/zero", "of=" + dev, "bs=1M", "count=1", "conv=notrunc"])
                if res.rc != 0:
                    fail("failed to wipe filesystem signatures: " + res.stderr)
            changed = True

    return {"changed": changed, "msg": "done"}
