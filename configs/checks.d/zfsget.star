def main(ctx, params):
    # ZFS filesystem usage check - read-only
    # Uses local df data combined with zfsget-style parsing

    # Default thresholds from Checkmk's FILESYSTEM_DEFAULT_PARAMS
    # The filesystem check uses: warn=80, crit=90 for used_percent (in %)
    # and warn/crit for growth (not relevant for basic usage check)

    excluded_mountpoints = ["/proc", "/sys", "/dev", "/run", "/snap", "/boot", "/lost+found"]

    if params.get("_discover"):
        # Probe for ZFS - check if zfs command exists
        zfs_probe = ctx.run(["zfs", "list", "-H", "-o", "name,mountpoint"],
                          mutates=False)
        if zfs_probe.rc == 127:
            # zfs not installed - no ZFS filesystems to discover
            return {"changed": False, "msg": "ZFS not installed",
                    "data": {"discovery": []}}

        if zfs_probe.rc != 0:
            # Error running zfs, or no pools/datasets
            return {"changed": False, "msg": "no ZFS datasets found",
                    "data": {"discovery": []}}

        # Parse ZFS datasets from output
        # Each line: name mountpoint
        discovery = []
        lines = zfs_probe.stdout.splitlines()
        for line in lines:
            parts = line.split()
            if len(parts) < 2:
                continue
            name = parts[0]
            mountpoint = parts[1]
            # Check if this is a usable filesystem with a mountpoint
            if mountpoint == "none" or mountpoint.startswith("/"):
                if mountpoint not in excluded_mountpoints:
                    # Use mountpoint as item identifier
                    discovery.append({
                        "item": mountpoint,
                        "params": {
                            "warn_used": 80,
                            "crit_used": 90,
                            "warn_free": 10,
                            "crit_free": 5,
                            "warn_growth": 0,
                            "crit_growth": 0,
                        },
                        "metrics": ["used_percent", "used", "total", "free"]
                    })

        return {"changed": False,
                "msg": "discovered %d ZFS filesystems" % len(discovery),
                "data": {"discovery": discovery}}

    # Check mode - examine one specific filesystem
    item = params.get("item", "")
    warn_used = params.get("warn_used", 80)
    crit_used = params.get("crit_used", 90)

    # Get df information for this mountpoint
    df_res = ctx.run(["df", "-k", item], mutates=False)

    if df_res.rc == 127:
        return {"changed": False, "msg": "df command not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if df_res.rc != 0:
        return {"changed": False,
                "msg": "mountpoint not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    lines = df_res.stdout.splitlines()
    if len(lines) < 2:
        return {"changed": False, "msg": "no data for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse df output: Filesystem 1K-blocks Used Available Use% Mounted on
    fields = lines[1].split()
    if len(fields) < 6:
        return {"changed": False, "msg": "unexpected df output for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Get usage percentage (strip % sign)
    used_percent_str = fields[4].rstrip("%")
    used_percent = int(used_percent_str) if used_percent_str.isdigit() else 0

    # Get sizes in KB, convert to bytes for metrics
    total_kb = int(fields[1]) if fields[1].isdigit() else 0
    used_kb = int(fields[2]) if fields[2].isdigit() else 0
    avail_kb = int(fields[3]) if fields[3].isdigit() else 0

    # Calculate percentage from kb values for accuracy
    if total_kb > 0:
        used_percent = int((used_kb * 100) / total_kb)
        free_percent = int((avail_kb * 100) / total_kb)
    else:
        free_percent = 100 - used_percent

    # Determine state based on thresholds
    state = "OK"
    if used_percent >= crit_used or free_percent <= params.get("crit_free", 5):
        state = "CRIT"
    elif used_percent >= warn_used or free_percent <= params.get("warn_free", 10):
        state = "WARN"

    msg = "%s %d%% used (%f GB of %f GB)" % (
        item, used_percent,
        total_kb / (1024*1024),
        (used_kb + avail_kb) / (1024*1024) if total_kb == 0 else total_kb / (1024*1024)
    )

    details = "Mountpoint: %s\nUsed: %f GB\nTotal: %f GB\nAvailable: %f GB" % (
        item,
        used_kb / (1024*1024),
        total_kb / (1024*1024),
        avail_kb / (1024*1024)
    )

    return {"changed": False,
            "msg": msg,
            "data": {
                "state": state,
                "metrics": {
                    "used_percent": used_percent,
                    "free_percent": free_percent,
                    "used": used_kb * 1024,
                    "total": total_kb * 1024,
                    "free": avail_kb * 1024
                },
                "details": details
            }}