def main(ctx, params):
    # Query btrfs filesystem info using 'btrfs filesystem show' and related commands
    # This is an info module: no writes, always read-only
    # Return format mirrors the original: {"changed": False, "filesystems": [...]}

    # Check for btrfs availability (read-only probe)
    probe = ctx.run(["which", "btrfs"], mutates=False, ok_codes=[0, 1])
    if probe.rc != 0:
        fail("btrfs command not found on system")

    # Get filesystems info: 'btrfs filesystem show' lists all mounted btrfs filesystems
    fs_show = ctx.run(["btrfs", "filesystem", "show"], mutates=False)
    if fs_show.rc != 0:
        fail("failed to run btrfs filesystem show: " + fs_show.stderr)

    filesystems = []
    lines = fs_show.stdout.strip().split("\n") if fs_show.stdout.strip() else []
    current_uuid = None
    current_label = None
    current_devices = []
    current_default_subvolid = None

    # Parse 'btrfs filesystem show' output
    for line in lines:
        line = line.strip()
        if not line:
            continue

        if "uuid:" in line and "Label:" in line:
            # Save previous filesystem if exists
            if current_uuid != None:
                filesystems.append({
                    "uuid": current_uuid,
                    "label": current_label if current_label != None else "",
                    "devices": sorted(list(set(current_devices))),
                    "default_subvolume": current_default_subvolid if current_default_subvolid != None else 0,
                })
            # Parse new filesystem
            parts = line.split()
            label = ""
            uuid = ""
            for i, part in enumerate(parts):
                if part == "Label:" and i + 1 < len(parts):
                    label = parts[i + 1].strip("'")
                if part == "uuid:" and i + 1 < len(parts):
                    uuid = parts[i + 1]
            current_uuid = uuid
            current_label = label if label else ""
            current_devices = []
            current_default_subvolid = 0
        elif line.startswith("Device "):
            tokens = line.split()
            if len(tokens) >= 2:
                dev = tokens[1]
                current_devices.append(dev)

    # Save last filesystem
    if current_uuid != None:
        filesystems.append({
            "uuid": current_uuid,
            "label": current_label if current_label != None else "",
            "devices": sorted(list(set(current_devices))),
            "default_subvolume": current_default_subvolid if current_default_subvolid != None else 0,
        })

    # For each filesystem, query subvolumes using 'btrfs subvolume list'
    for fs in filesystems:
        uuid = fs["uuid"]

        # Collect mountpoints for this UUID
        mounts = []
        findmnt = ctx.run(["findmnt", "-n", "-o", "TARGET", "-t", "btrfs"], mutates=False)
        if findmnt.rc == 0 and findmnt.stdout.strip():
            for m in findmnt.stdout.strip().split("\n"):
                m = m.strip()
                if m:
                    usage = ctx.run(["btrfs", "filesystem", "usage", "-b", m], mutates=False, ok_codes=[0, 1])
                    if usage.rc == 0:
                        for u in usage.stdout.split("\n"):
                            if "UUID:" in u and uuid in u:
                                mounts.append(m)
                                break

        # Now get subvolumes per mountpoint
        seen_subvolumes = {}
        for m in mounts:
            subvols = ctx.run(["btrfs", "subvolume", "list", "-a", m], mutates=False, ok_codes=[0, 1])
            if subvols.rc == 0 and subvols.stdout.strip():
                for line in subvols.stdout.strip().split("\n"):
                    line = line.strip()
                    if not line:
                        continue
                    tokens = line.split()
                    if len(tokens) >= 5 and tokens[0] == "ID" and tokens[2] == "gen" and tokens[3] == "top" and tokens[4] == "level":
                        subv_id = int(tokens[1])
                        subv_parent = int(tokens[5])
                        subv_path = tokens[7] if len(tokens) > 7 else ""
                        if subv_id not in seen_subvolumes:
                            seen_subvolumes[subv_id] = {
                                "id": subv_id,
                                "parent": subv_parent,
                                "path": subv_path,
                                "mountpoints": [m] if m else [],
                            }
                        else:
                            if m not in seen_subvolumes[subv_id]["mountpoints"]:
                                seen_subvolumes[subv_id]["mountpoints"].append(m)

        for sv in seen_subvolumes.values():
            sv["mountpoints"] = sorted(list(set(sv["mountpoints"])))

        fs["subvolumes"] = sorted(seen_subvolumes.values(), key=lambda x: x["id"])

        # Determine default subvolume
        default_id = 0
        if mounts:
            default_cmd = ctx.run(["btrfs", "subvolume", "get-default", mounts[0]], mutates=False, ok_codes=[0, 1])
            if default_cmd.rc == 0 and default_cmd.stdout.strip():
                for line in default_cmd.stdout.strip().split("\n"):
                    if line.startswith("ID "):
                        parts = line.split()
                        if len(parts) >= 2:
                            default_id = int(parts[1])
                            break
        fs["default_subvolume"] = default_id

    return {"changed": False, "msg": "btrfs filesystem info collected", "data": {"filesystems": filesystems}}
