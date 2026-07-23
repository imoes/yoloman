# ===== Starlark check module: aix_multipath =====
# Read-only check for AIX multipath device status

# Parse function: expects agent section output like:
# hdisk0 vscsi0 Available Enabled
# hdisk1 vscsi0 Available Enabled
# hdisk2 vscsi0 Available Enabled

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["lsdev", "-Cc", "disk"], mutates=False)
        disks = {}
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 4 and parts[0].startswith("hdisk"):
                disk = parts[0]
                # Only consider disks with status "Available"
                if parts[2] == "Available":
                    disks[disk] = disks.get(disk, 0) + 1
        out = []
        for disk, paths in disks.items():
            out.append({"item": disk, "params": {"paths": paths}, "metrics": []})
        return {"changed": False, "msg": "discovered %d multipath devices" % len(out),
                "data": {"discovery": out}}

    # Check mode (non-discovery)
    item = params.get("item", "")
    res = ctx.run(["lsdev", "-Cc", "disk"], mutates=False)
    
    path_count = 0
    state_count = 0
    
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 4 and parts[0] == item:
            if parts[2] == "Available":
                path_count += 1
                if parts[3] != "Enabled":
                    state_count += 1
    
    # If no such disk found
    if path_count == 0:
        return {"changed": False, "msg": "disk %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Calculate state based on non-enabled paths
    state = "OK"
    summary_parts = []
    
    # Check for paths not enabled
    if state_count != 0:
        percentage = (100.0 / path_count) * state_count
        if percentage < 50.0:
            state = "WARN"
            summary_parts.append("Paths not enabled: %d" % state_count)
        else:
            state = "CRIT"
            summary_parts.append("Paths not enabled: %d" % state_count)
    
    # Check for missing paths (should match discovered paths)
    expected_paths = params.get("paths", 0)
    if path_count != expected_paths:
        state = "WARN"
        summary_parts.append("Paths in total: %d (should be: %d)" % (path_count, expected_paths))
    else:
        summary_parts.append("Paths in total: %d" % path_count)
    
    summary = ", ".join(summary_parts)
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": ""}}
