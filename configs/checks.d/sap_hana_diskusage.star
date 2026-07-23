def main(ctx, params):
    # Helper: extract size/used from agent output line (GB -> MB)
    def extract_size_used(line):
        parts = line.strip().split()
        if len(parts) < 6:
            return None, None
        size_gb_str = parts[1]
        used_gb_str = parts[4]
        if not size_gb_str.replace(".", "", 1).replace("-", "", 1).isdigit() or not used_gb_str.replace(".", "", 1).replace("-", "", 1).isdigit():
            return None, None
        size_gb = float(size_gb_str)
        used_gb = float(used_gb_str)
        size_mb = size_gb * 1024.0
        used_mb = used_gb * 1024.0
        return size_mb, used_mb

    # Discover mode: enumerate all SAP HANA disk entries
    if params.get("_discover"):
        res = ctx.run(["cmk-agent-ctl", "list-sections"], mutates=False)
        # If sap_hana_diskusage section is missing, return empty discovery
        if "sap_hana_diskusage" not in res.stdout:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

        # Run raw agent command to get sap_hana_diskusage section
        # Agent output format: one line per instance+disk, e.g.:
        # SID-INST  OK  data  size_gb used_gb ...
        # We parse all lines and produce one item per line.
        agent_res = ctx.run(["cmk-agent-ctl", "run", "sap_hana_diskusage"], mutates=False)
        if agent_res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

        out = []
        for line in agent_res.stdout.splitlines():
            if not line.strip():
                continue
            # Extract first field (SID-INSTANCE) and second field (state_name)
            fields = line.strip().split()
            if len(fields) < 2:
                continue
            sid_instance = fields[0]
            state_name = fields[1]
            # Build item name: "SID-INSTANCE - disk"
            # The actual disk name is the 3rd field
            disk_name = fields[2] if len(fields) >= 3 else "data"
            item_name = "%s - %s" % (sid_instance, disk_name)
            # Extract size/used in MB
            size_mb, used_mb = extract_size_used(line)
            suggested_params = {
                "levels": (80.0, 90.0),  # default warn/crit percent
                "magic_norm_factor": 0.0,
                "show_levels": "onwarning",
                "show_inodes": "onlow",
                "show_time_left": "onlow",
                "total_size": 0.0,
            }
            # Build metrics list (the perfdata names this item yields)
            metrics = ["used_percent", "used", "free", "total"]
            out.append({"item": item_name, "params": suggested_params, "metrics": metrics})
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    # Check mode: inspect one specific item
    item = params.get("item", "")
    agent_res = ctx.run(["cmk-agent-ctl", "run", "sap_hana_diskusage"], mutates=False)
    if agent_res.rc != 0:
        return {"changed": False, "msg": "agent command failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Find the line matching this item
    line_found = ""
    for line in agent_res.stdout.splitlines():
        if not line.strip():
            continue
        fields = line.strip().split()
        if len(fields) < 2:
            continue
        sid_instance = fields[0]
        disk_name = fields[2] if len(fields) >= 3 else "data"
        candidate = "%s - %s" % (sid_instance, disk_name)
        if candidate == item:
            line_found = line
            break

    if not line_found:
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse state, size, used
    fields = line_found.strip().split()
    if len(fields) < 3:
        return {"changed": False, "msg": "malformed agent output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_name = fields[1]
    size_mb, used_mb = extract_size_used(line_found)
    if size_mb == None or used_mb == None:
        return {"changed": False, "msg": "missing size or used value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Translate state
    if state_name == "OK":
        state = "OK"
    elif state_name == "UNKNOWN":
        state = "UNKNOWN"
    else:
        state = "CRIT"

    # Compute filesystem levels (from params or defaults)
    # Checkmk defaults for filesystem levels
    warn_pct = params.get("levels", (80.0, 90.0))[0] if isinstance(params.get("levels"), tuple) else 80.0
    crit_pct = params.get("levels", (80.0, 90.0))[1] if isinstance(params.get("levels"), tuple) else 90.0
    # Also accept absolute levels if present (bytes) — convert to MB
    if "levels" in params and type(params.get("levels")) == "dict":
        warn_pct = params.get("levels", {}).get("levels_low", warn_pct)
        crit_pct = params.get("levels", {}).get("levels", crit_pct)
    # Simulate df check: compute percentage and compare against warn/crit
    avail_mb = size_mb - used_mb
    used_pct = (used_mb / size_mb * 100.0) if size_mb > 0 else 0.0

    # Apply threshold logic
    if state_name != "OK":
        # Already decided by state_name (CRIT or UNKNOWN)
        pass
    else:
        # Apply percentage levels to override state
        if used_pct >= crit_pct:
            state = "CRIT"
        elif used_pct >= warn_pct:
            state = "WARN"

    # Build metrics
    metrics = {
        "used_percent": used_pct,
        "used": used_mb,
        "free": avail_mb,
        "total": size_mb,
    }

    msg = "Status: %s, Total: %f MB, Used: %f MB (%f%%), Free: %f MB" % (
        state_name, size_mb, used_mb, used_pct, avail_mb
    )

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}
