def main(ctx, params):
    # Helper to split mount options, handling backslash-escaped space (040)
    def parse_mount_line(line):
        parts = line.split()
        if len(parts) < 6:
            return None
        dev, mountpoint, fs_type, options, _, _ = parts[:6]
        # Restore escaped space: \040 -> space then trim "(deleted)"
        mountpoint_clean = mountpoint.replace("\\040 ", " ").replace("\\040(deleted)", "")
        is_stale = mountpoint.endswith("\\040(deleted)")
        opts = sorted(options.split(","))
        return {
            "device": dev,
            "mountpoint": mountpoint_clean,
            "original_mountpoint": mountpoint,
            "fs_type": fs_type,
            "options": opts,
            "is_stale": is_stale,
        }

    # Helper: decide if option should be ignored
    def _should_ignore_option(opt):
        prefixes = ["commit=", "localalloc=", "subvol=", "subvolid="]
        for p in prefixes:
            if opt.startswith(p):
                return True
        return False

    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/mounts"], mutates=False)
        mounts = []
        seen_devices = set()
        for line in res.stdout.splitlines():
            parsed = parse_mount_line(line)
            if parsed == None:
                continue
            dev = parsed["device"]
            if dev in seen_devices:
                continue
            seen_devices.add(dev)

            # Skip tmpfs and special paths
            if parsed["fs_type"] == "tmpfs":
                continue
            mp = parsed["mountpoint"]
            if mp in ["/etc/resolv.conf", "/etc/hostname", "/etc/hosts"]:
                continue

            mounts.append({
                "item": mp,
                "params": {"expected_mount_options": []},
                "metrics": [],
            })
        return {
            "changed": False,
            "msg": "discovered %d mounts" % len(mounts),
            "data": {"discovery": mounts},
        }

    # Check mode
    item = params.get("item", "")
    res = ctx.run(["cat", "/proc/mounts"], mutates=False)
    section = {}
    seen_devices = set()
    for line in res.stdout.splitlines():
        parsed = parse_mount_line(line)
        if parsed == None:
            continue
        dev = parsed["device"]
        if dev in seen_devices:
            continue
        seen_devices.add(dev)

        mp = parsed["mountpoint"]
        if parsed["fs_type"] != "tmpfs" and mp not in ["/etc/resolv.conf", "/etc/hostname", "/etc/hosts"]:
            section[mp] = parsed

    if section.get(item) == None:
        return {
            "changed": False,
            "msg": "mount not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    mount = section.get(item)
    expected = params.get("expected_mount_options", [])

    if mount["is_stale"]:
        return {
            "changed": False,
            "msg": "Mount point detected as stale",
            "data": {"state": "WARN", "metrics": {}, "details": ""},
        }

    exceeding = []
    missing = []

    # Compute exceeding: options present but not expected (and not ignored)
    for opt in mount["options"]:
        if not _should_ignore_option(opt) and opt not in expected:
            exceeding.append(opt)

    # Compute missing: expected but not present (and not ignored)
    for opt in expected:
        if not _should_ignore_option(opt) and opt not in mount["options"]:
            missing.append(opt)

    if not missing and not exceeding:
        return {
            "changed": False,
            "msg": "Mount options exactly as expected",
            "data": {"state": "OK", "metrics": {}, "details": ""},
        }

    summary_parts = []
    state = "WARN"

    if missing:
        summary_parts.append("Missing: " + ",".join(missing))
    if exceeding:
        summary_parts.append("Exceeding: " + ",".join(exceeding))

    if "ro" in exceeding:
        state = "CRIT"
        summary_parts.append("Filesystem has switched to read-only and is probably corrupted")

    return {
        "changed": False,
        "msg": "; ".join(summary_parts),
        "data": {"state": state, "metrics": {}, "details": ""},
    }