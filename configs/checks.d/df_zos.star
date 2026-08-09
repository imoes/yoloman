def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["df", "-P"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no filesystem data available",
                    "data": {"discovery": []}}

        items = []
        lines = res.stdout.splitlines()
        # Skip header line
        for line in lines[1:]:
            fields = line.split()
            if len(fields) < 6:
                continue
            filesystem = fields[0]
            mount = fields[5]
            # Filter out AUTOMNT, TFS, NFS and read-only filesystems
            if filesystem in ["AUTOMNT", "TFS", "NFS"]:
                continue
            # Read-only check: assume read-only if no write permission indication
            # For df -P output, we can't easily detect read-only status
            # We'll assume read/write unless filesystem is explicitly read-only
            # Since the original check filters "Read/Write" in options, and
            # this is a simplified check on non-z/OS systems, we include all
            # except excluded types
            items.append({
                "item": mount,
                "params": {"levels": (80.0, 90.0)},
                "metrics": ["used_percent"]
            })

        return {"changed": False, "msg": "discovered %d filesystems" % len(items),
                "data": {"discovery": items}}

    # Check mode: single item
    item = params.get("item", "")
    res = ctx.run(["df", "-P", item], mutates=False)
    if res.rc != 0 or len(res.stdout.splitlines()) < 2:
        return {"changed": False, "msg": "filesystem not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    fields = res.stdout.splitlines()[1].split()
    if len(fields) < 6:
        return {"changed": False, "msg": "cannot parse df output for: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # fields: Filesystem 1024-blocks Used Available Capacity Mounted
    size_kb = float(fields[1])
    used_kb = float(fields[2])
    # Calculate used percent
    if size_kb > 0:
        used_percent = (used_kb / size_kb) * 100.0
    else:
        used_percent = 0.0

    # Get thresholds - use Checkmk defaults
    levels = params.get("levels", (80.0, 90.0))
    warn = levels[0] if isinstance(levels, tuple) else levels
    crit = levels[1] if isinstance(levels, tuple) else 90.0

    # Determine state
    if used_percent >= crit:
        state = "CRIT"
    elif used_percent >= warn:
        state = "WARN"
    else:
        state = "OK"

    msg = "%s %f%% used" % (item, used_percent)
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"used_percent": used_percent}, "details": ""}}
