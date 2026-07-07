def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    automount = params.get("automount", False)
    default = params.get("default", False)
    filesystem_device = params.get("filesystem_device")
    filesystem_label = params.get("filesystem_label")
    filesystem_uuid = params.get("filesystem_uuid")
    recursive = params.get("recursive", False)
    snapshot_conflict = params.get("snapshot_conflict", "skip")
    snapshot_source = params.get("snapshot_source")

    if state not in ["present", "absent"]:
        fail("unsupported state: " + state)
    if snapshot_conflict not in ["skip", "clobber", "error"]:
        fail("unsupported snapshot_conflict: " + snapshot_conflict)

    # BTRFS root subvolume IDs
    BTRFS_ROOT_SUBVOLUME_ID = 5

    # Detect filesystem
    filesystem = _detect_filesystem(ctx, filesystem_device, filesystem_label, filesystem_uuid, automount)
    if filesystem == None:
        fail("Failed to identify targeted filesystem")

    # Ensure root subvolume is mounted if needed
    if automount and not filesystem["mounted"]:
        root_mount_path = _mount_root_subvolume(ctx, filesystem, BTRFS_ROOT_SUBVOLUME_ID)
        filesystem["mounted"] = True
        filesystem["mountpath"] = root_mount_path
    elif not filesystem["mounted"] and not automount:
        fail("Target filesystem is not mounted and automount=False")

    target_mountpath = _construct_mountpath_for_subvolume(ctx, filesystem, name)

    # Get current state
    current_subvolume = _get_subvolume_by_path(ctx, filesystem, name)

    changed = False
    msg = ""
    modifications = []
    target_id = None

    if state == "present":
        if snapshot_source == None:
            # Create subvolume
            if current_subvolume == None:
                # Ensure parent is mounted (if needed for intermediate dirs)
                if recursive:
                    _ensure_intermediate_mounts(ctx, filesystem, name, automount)
                # Check existence of parent dir (simulate intermediate creation)
                parent_mountpath = _construct_mountpath_for_subvolume(ctx, filesystem, "/")
                if not ctx.file_exists(parent_mountpath):
                    fail("Parent directory does not exist: " + parent_mountpath)

                if ctx.check_mode:
                    return {"changed": True, "msg": "would create subvolume " + name}

                res = ctx.run(["btrfs", "subvolume", "create", target_mountpath], mutates=True)
                if res.skipped:
                    return {"changed": True, "msg": "would create subvolume " + name}
                if res.rc != 0:
                    fail("failed to create subvolume " + name + ": " + res.stderr)

                changed = True
                msg = "Created subvolume " + name
                modifications.append("Created subvolume '" + name + "'")
                # Refresh target_id
                refreshed = _get_subvolume_by_path(ctx, filesystem, name)
                target_id = refreshed["id"] if refreshed else None
            else:
                msg = "Subvolume " + name + " already exists"
        else:
            # Create snapshot
            snapshot_source_path = snapshot_source
            source_subvolume = _get_subvolume_by_path(ctx, filesystem, snapshot_source_path)
            if source_subvolume == None:
                fail("Source subvolume " + snapshot_source_path + " does not exist")

            if current_subvolume != None:
                if snapshot_conflict == "skip":
                    msg = "Snapshot target already exists; skipped"
                    target_id = current_subvolume["id"]
                elif snapshot_conflict == "error":
                    fail("Target subvolume " + name + " already exists and snapshot_conflict='error'")
                elif snapshot_conflict == "clobber":
                    if ctx.check_mode:
                        return {"changed": True, "msg": "would clobber and create snapshot " + name}
                    res = ctx.run(["btrfs", "subvolume", "delete", target_mountpath], mutates=True)
                    if res.skipped:
                        return {"changed": True, "msg": "would clobber and create snapshot " + name}
                    if res.rc != 0:
                        fail("failed to delete existing subvolume " + name + ": " + res.stderr)
                    current_subvolume = None
                else:
                    fail("unsupported snapshot_conflict: " + snapshot_conflict)
            else:
                if ctx.check_mode:
                    return {"changed": True, "msg": "would create snapshot " + name}

                source_mountpath = _construct_mountpath_for_subvolume(ctx, filesystem, snapshot_source_path)
                res = ctx.run(["btrfs", "subvolume", "snapshot", source_mountpath, target_mountpath], mutates=True)
                if res.skipped:
                    return {"changed": True, "msg": "would create snapshot " + name}
                if res.rc != 0:
                    fail("failed to create snapshot " + name + ": " + res.stderr)

                changed = True
                msg = "Created snapshot " + name + " from " + snapshot_source_path
                modifications.append("Created snapshot '" + name + "' from '" + snapshot_source_path + "'")
                refreshed = _get_subvolume_by_path(ctx, filesystem, name)
                target_id = refreshed["id"] if refreshed else None

        # Handle default subvolume
        if default:
            target_subvolume = _get_subvolume_by_path(ctx, filesystem, name)
            target_id = target_subvolume["id"] if target_subvolume else None

            if filesystem["default_subvolid"] != target_id:
                if ctx.check_mode:
                    return {"changed": True, "msg": "would set default subvolume to " + name}
                res = ctx.run(["btrfs", "subvolume", "set-default", str(target_id), filesystem["mountpath"]], mutates=True)
                if res.skipped:
                    return {"changed": True, "msg": "would set default subvolume to " + name}
                if res.rc != 0:
                    fail("failed to set default subvolume: " + res.stderr)
                changed = True
                modifications.append("Updated default subvolume to '" + name + "' (" + str(target_id) + ")")
            else:
                if not changed:
                    msg = "Subvolume " + name + " already in desired state"

    elif state == "absent":
        if current_subvolume == None:
            msg = "Subvolume " + name + " does not exist"
        else:
            # Ensure no children if not recursive
            children = _get_child_subvolumes(ctx, filesystem, current_subvolume["id"])
            if not recursive and len(children) > 0:
                fail("Subvolume targeted for deletion " + name + " has children and recursive=False")

            if ctx.check_mode:
                return {"changed": True, "msg": "would delete subvolume " + name}

            # Delete subvolume
            res = ctx.run(["btrfs", "subvolume", "delete", target_mountpath], mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would delete subvolume " + name}
            if res.rc != 0:
                fail("failed to delete subvolume " + name + ": " + res.stderr)

            changed = True
            msg = "Deleted subvolume " + name
            modifications.append("Deleted subvolume '" + name + "'")

    # Cleanup temporary mounts (simulated)
    # In Starlark, we can't actually umount — assume ctx handles it via mount manager if implemented
    return {"changed": changed, "msg": msg, "data": {
        "filesystem": filesystem,
        "modifications": modifications,
        "target_subvolume_id": target_id
    }}


def _detect_filesystem(ctx, device, label, uuid, automount):
    res = ctx.run(["btrfs", "filesystem", "show"], mutates=False)
    if res.rc != 0:
        return None

    # Parse show output to find matching filesystem
    # Simplified: just return first available if criteria unspecified
    lines = res.stdout.splitlines()
    fs = None
    for line in lines:
        if "uuid:" in line:
            parts = line.split()
            current_uuid = None
            current_label = None
            current_devices = []
            for p in parts:
                if "uuid:" in p:
                    current_uuid = p.split(":")[-1]
                elif "label:" in p:
                    current_label = p.split(":")[-1]
                elif p.startswith("/dev/"):
                    current_devices.append(p)
            if current_uuid:
                fs = {
                    "uuid": current_uuid,
                    "label": current_label,
                    "devices": current_devices,
                    "mounted": False,
                    "mountpath": None,
                    "default_subvolid": None,
                    "subvolumes": []
                }
                break

    if fs == None:
        return None

    # Try to determine if mounted
    res2 = ctx.run(["btrfs", "filesystem", "df", fs["devices"][0] if fs["devices"] else "/"], mutates=False)
    # Not reliable; we'll check mount info separately
    # For now, assume mounted if we have a mountpath
    # Try to mount path to verify
    if fs["devices"]:
        mountpath = fs["devices"][0]
        res3 = ctx.run(["findmnt", "-n", "-o", "TARGET", "-S", mountpath], mutates=False)
        if res3.rc == 0 and res3.stdout.strip():
            fs["mounted"] = True
            fs["mountpath"] = res3.stdout.strip().splitlines()[0]

    # Get default subvolume if mounted
    if fs["mounted"] and fs["mountpath"]:
        res4 = ctx.run(["btrfs", "subvolume", "get-default", fs["mountpath"]], mutates=False)
        if res4.rc == 0:
            for line in res4.stdout.splitlines():
                if "id " in line:
                    parts = line.split()
                    for p in parts:
                        if p.isdigit():
                            fs["default_subvolid"] = int(p)
                            break

    # Match criteria
    if device:
        if device not in fs["devices"]:
            return None
    if label:
        if fs["label"] != label:
            return None
    if uuid:
        if fs["uuid"] != uuid:
            return None

    return fs


def _mount_root_subvolume(ctx, filesystem, subvolid):
    if not filesystem["devices"]:
        fail("No devices available to mount filesystem")
    device = filesystem["devices"][0]
    # Use /tmp as mountpoint prefix (simplified)
    mountpoint = "/tmp/btrfs_" + str(subvolid)
    # Ensure directory exists (simulated)
    ctx.run(["mkdir", "-p", mountpoint], mutates=True)
    res = ctx.run(["mount", "-o", "noatime,subvolid=" + str(subvolid), device, mountpoint], mutates=True)
    if res.rc != 0:
        fail("Failed to mount subvolume " + str(subvolid) + ": " + res.stderr)
    return mountpoint


def _construct_mountpath_for_subvolume(ctx, filesystem, name):
    base = filesystem["mountpath"]
    if base.endswith("/"):
        base = base[:-1]
    # Normalize name to start with /
    if not name.startswith("/"):
        name = "/" + name
    # If root, return base
    if name == "/":
        return base
    return base + name


def _get_subvolume_by_path(ctx, filesystem, name):
    if not filesystem["mounted"]:
        return None
    mountpath = _construct_mountpath_for_subvolume(ctx, filesystem, name)
    res = ctx.run(["btrfs", "subvolume", "list", "-a", mountpath], mutates=False)
    if res.rc != 0:
        return None

    # Parse output
    lines = res.stdout.splitlines()
    for line in lines:
        parts = line.split()
        if len(parts) >= 8:
            # Format: id <id> gen <gen> top_level <top> path <path>
            if len(parts) >= 7 and parts[0] == "id" and parts[4] == "path":
                subvolid = int(parts[1])
                path = parts[6]
                if path == name or path == name.lstrip("/"):
                    # Resolve mountpoints
                    return {"id": subvolid, "path": path, "mountpoints": [mountpath], "parent": int(parts[3]), "is_root": path == "/" or path == ""}
    return None


def _get_child_subvolumes(ctx, filesystem, parent_id):
    if not filesystem["mounted"]:
        return []
    mountpath = filesystem["mountpath"]
    res = ctx.run(["btrfs", "subvolume", "list", "-a", mountpath], mutates=False)
    if res.rc != 0:
        return []

    children = []
    lines = res.stdout.splitlines()
    for line in lines:
        parts = line.split()
        if len(parts) >= 8:
            if parts[0] == "id" and len(parts) >= 7:
                subvolid = int(parts[1])
                top_level = int(parts[3])
                if top_level == parent_id:
                    children.append({"id": subvolid, "parent": parent_id})
    return children


def _ensure_intermediate_mounts(ctx, filesystem, name, automount):
    # Construct parent path and mount it if needed (simulated)
    # For Starlark, assume intermediate mounting handled by root mount
    pass
