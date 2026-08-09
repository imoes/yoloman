def main(ctx, params):
    filesystem = params["filesystem"]
    state = params.get("state", "present")
    fs_type = params.get("fs_type", "jfs2")
    device = params.get("device")
    vg = params.get("vg")
    nfs_server = params.get("nfs_server")
    permissions = params.get("permissions", "rw")
    auto_mount = params.get("auto_mount", True)
    account_subsystem = params.get("account_subsystem", False)
    rm_mount_point = params.get("rm_mount_point", False)
    size = params.get("size")
    attributes = params.get("attributes", ["agblksize='4096'", "isnapshot='no'"])
    mount_group = params.get("mount_group")

    # Helper: check if filesystem is mounted
    mount_cmd = ctx.run(["mount"], mutates=False)
    if mount_cmd.rc != 0:
        fail("Failed to run mount: " + mount_cmd.stderr)
    mount_output = mount_cmd.stdout
    is_mounted = False
    for line in mount_output.splitlines():
        if line.startswith(filesystem + " ") or line == filesystem:
            is_mounted = True
            break

    # Helper: check if filesystem exists via lsfs
    lsfs_cmd = ctx.run(["lsfs", "-l", filesystem], mutates=False)
    fs_exists = lsfs_cmd.rc == 0 and "No record matching" not in lsfs_cmd.stderr

    # Helper: validate volume group
    if vg != None:
        lsvg_active = ctx.run(["lsvg", "-o"], mutates=False)
        lsvg_all = ctx.run(["lsvg"], mutates=False)
        if lsvg_active.rc != 0 or lsvg_all.rc != 0:
            fail("Failed to run lsvg")
        active_vgs = set(lsvg_active.stdout.strip().split())
        all_vgs = set(lsvg_all.stdout.strip().split())
        if vg in all_vgs and vg not in active_vgs:
            return {"changed": False, "msg": "Volume group %s is in varyoff state." % vg}
        elif vg not in all_vgs:
            return {"changed": False, "msg": "Volume group %s does not exist." % vg}

    # Handle states
    if state == "present":
        if is_mounted or fs_exists:
            msg = "File system %s already exists." % filesystem
            changed = False
            if size != None:
                chfs_cmd = ctx.run(
                    ["chfs", "-a", "size=" + size, filesystem], mutates=True
                )
                if chfs_cmd.skipped:
                    return {"changed": True, "msg": "would resize " + filesystem}
                if chfs_cmd.rc == 28:
                    changed = False
                elif chfs_cmd.rc != 0:
                    if "Maximum allocation for logical" in chfs_cmd.stderr:
                        changed = False
                    else:
                        fail("Failed to resize filesystem: " + chfs_cmd.stderr)
                else:
                    if "The filesystem size is already" in chfs_cmd.stdout:
                        changed = False
                    else:
                        changed = True
                return {"changed": changed, "msg": msg + " " + chfs_cmd.stdout.strip()}
            return {"changed": changed, "msg": msg}

        # Create filesystem
        if nfs_server != None:
            # NFS
            if device == None:
                return {"changed": False, "msg": 'Parameter "device" is required when "nfs_server" is defined.'}

            # Check if NFS export exists via showmount (readonly)
            showmount = ctx.run(["showmount", "-a", nfs_server], mutates=False)
            if showmount.rc != 0:
                fail("Failed to run showmount: " + showmount.stderr)
            nfs_export_exists = False
            for line in showmount.stdout.splitlines():
                if ":" in line:
                    parts = line.split(":")
                    if len(parts) > 1 and parts[1] == device:
                        nfs_export_exists = True
                        break

            if not nfs_export_exists:
                fail("NFS export %s not found on server %s" % (device, nfs_server))

            # Create NFS mount point
            if not ctx.check_mode:
                auto_mount_opt = "-A" if auto_mount else "-a"
                mknfsmnt_cmd = ctx.run(
                    [
                        "mknfsmnt",
                        "-f",
                        filesystem,
                        device,
                        "-h",
                        nfs_server,
                        "-t",
                        permissions,
                        auto_mount_opt,
                        "-w",
                        "bg",
                    ],
                    mutates=True,
                )
                if mknfsmnt_cmd.rc != 0:
                    fail("Failed to create NFS mount: " + mknfsmnt_cmd.stderr)
                return {"changed": True, "msg": "NFS file system %s created." % filesystem}
            return {"changed": True, "msg": "would create NFS file system " + filesystem}

        else:
            # LVM
            if device == None and vg == None:
                return {
                    "changed": False,
                    "msg": 'Required parameter "device" and/or "vg" is missing for filesystem creation.',
                }

            # Prepare options
            opts = ["-v", fs_type, "-m", filesystem]
            if vg != None:
                opts += ["-g", vg]
            if device != None:
                opts += ["-d", device]
            if mount_group != None:
                opts += ["-u", mount_group]
            auto_mount_opt = "-A"
            if auto_mount:
                auto_mount_opt += " yes"
            else:
                auto_mount_opt += " no"
            opts += [auto_mount_opt]
            account_opt = "-t"
            if account_subsystem:
                account_opt += " yes"
            else:
                account_opt += " no"
            opts += [account_opt]
            opts += ["-p", permissions]
            if size != None:
                opts += ["-a", "size=" + size]
            # Attributes
            for attr in attributes:
                opts += ["-a", attr]

            if not ctx.check_mode:
                crfs_cmd = ctx.run(["crfs"] + opts, mutates=True)
                if crfs_cmd.rc == 10:
                    fail(
                        "Using a existent previously defined logical volume, volume group needs to be empty: %s"
                        % crfs_cmd.stderr
                    )
                elif crfs_cmd.rc != 0:
                    fail("Failed to create filesystem: " + crfs_cmd.stderr)
                return {
                    "changed": True,
                    "msg": "File system %s created." % filesystem,
                }
            return {"changed": True, "msg": "would create file system " + filesystem}

    elif state == "absent":
        if is_mounted:
            return {"changed": False, "msg": "File system %s mounted." % filesystem}

        if not fs_exists:
            return {"changed": False, "msg": "File system %s does not exist." % filesystem}

        rm_opts = ["-r"]
        if rm_mount_point:
            rm_opts.append("yes")
        else:
            rm_opts.append("")
        if not ctx.check_mode:
            rmfs_cmd = ctx.run(["rmfs"] + rm_opts + [filesystem], mutates=True)
            if rmfs_cmd.rc != 0:
                fail("Failed to remove filesystem: " + rmfs_cmd.stderr)
            msg = (
                rmfs_cmd.stdout.strip()
                if rmfs_cmd.stdout.strip()
                else "File system %s removed." % filesystem
            )
            return {"changed": True, "msg": msg}
        return {"changed": True, "msg": "would remove file system " + filesystem}

    elif state == "mounted":
        if is_mounted:
            return {"changed": False, "msg": "File system %s already mounted." % filesystem}
        if not ctx.check_mode:
            mount_cmd = ctx.run(["mount", filesystem], mutates=True)
            if mount_cmd.rc != 0:
                fail("Failed to mount filesystem: " + mount_cmd.stderr)
            return {"changed": True, "msg": "File system %s mounted." % filesystem}
        return {"changed": True, "msg": "would mount file system " + filesystem}

    elif state == "unmounted":
        if not is_mounted:
            return {"changed": False, "msg": "File system %s already unmounted." % filesystem}
        if not ctx.check_mode:
            unmount_cmd = ctx.run(["unmount", filesystem], mutates=True)
            if unmount_cmd.rc != 0:
                fail("Failed to unmount filesystem: " + unmount_cmd.stderr)
            return {"changed": True, "msg": "File system %s unmounted." % filesystem}
        return {"changed": True, "msg": "would unmount file system " + filesystem}

    fail("Unexpected state: " + state)
