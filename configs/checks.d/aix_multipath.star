def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["lsdev", "-Cc", "disk"], mutates=False)
        disks = {}
        # Parse output like: "hdisk0 Available 00-00-00"
        for line in res.stdout.splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[0].startswith("hdisk"):
                disk = parts[0]
                status = parts[1]
                # Only count available disks
                if status == "Available":
                    disks[disk] = disks.get(disk, 0) + 1
        out = []
        for disk, paths in disks.items():
            out.append({"item": disk, "params": {"paths": paths}, "metrics": []})
        return {"changed": False, "msg": "discovered %d multipath devices" % len(out),
                "data": {"discovery": out}}
    
    item = params.get("item", "")
    res = ctx.run(["lsdev", "-Cc", "disk"], mutates=False)
    path_count = 0
    state_count = 0
    expected_paths = params.get("paths", 0)
    
    for line in res.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[0] == item:
            status = parts[1]
            # Only count available disks
            if status == "Available":
                path_count += 1
                # Count paths that are not enabled
                if parts[2] != "Enabled":
                    state_count += 1
    
    # Check if item exists
    if path_count == 0:
        return {"changed": False, "msg": "multipath device %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    state = "OK"
    msg_parts = ["Paths in total: %d" % path_count]
    
    # Check for non-enabled paths
    if state_count != 0:
        pct = (100.0 / path_count * state_count)
        if pct >= 50.0:
            state = "CRIT"
        else:
            state = "WARN"
        msg_parts.append("Paths not enabled: %d" % state_count)
    
    # Check path count matches expected
    if path_count != expected_paths:
        state = "WARN" if state == "OK" else state
        msg_parts.append("(should be: %d)" % expected_paths)
    
    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }
