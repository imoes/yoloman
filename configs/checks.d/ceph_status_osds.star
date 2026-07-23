def main(ctx, params):
    # Run the ceph status command to get OSD data
    res = ctx.run(["ceph", "status", "--format", "json"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "ceph status command failed", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    if not res.stdout:
        return {"changed": False, "msg": "no data from ceph status", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    data = json.decode(res.stdout)
    
    # Extract osdmap data (handle both flat and nested structures)
    osdmap = data.get("osdmap", {})
    if isinstance(osdmap, dict) and "osdmap" in osdmap:
        data = osdmap.get("osdmap", osdmap)
    else:
        data = osdmap
    
    # Get OSD count
    num_osds = int(data.get("num_osds", 0))
    if num_osds == 0:
        return {"changed": False, "msg": "no OSDs found", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Check full/nearfull flags
    full = data.get("full", False)
    nearfull = data.get("nearfull", False)
    
    if full:
        return {"changed": False, "msg": "Full", 
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    
    if nearfull:
        return {"changed": False, "msg": "Near full", 
                "data": {"state": "WARN", "metrics": {}, "details": ""}}
    
    # Compute OSD out/down percentages
    num_in_osds = int(data.get("num_in_osds", num_osds))
    num_up_osds = int(data.get("num_up_osds", num_osds))
    
    num_out = num_osds - num_in_osds
    num_down = num_osds - num_up_osds
    
    out_pct = 100.0 * float(num_out) / float(num_osds)
    down_pct = 100.0 * float(num_down) / float(num_osds)
    
    # Apply thresholds (Checkmk defaults: (5.0, 7.0) for num_out_osds, num_down_osds)
    warn_out, crit_out = params.get("num_out_osds", (5.0, 7.0))
    warn_down, crit_down = params.get("num_down_osds", (5.0, 7.0))
    
    state = "OK"
    
    # Check OSDs out percentage
    if out_pct >= crit_out:
        state = "CRIT"
    elif out_pct >= warn_out and state not in ("CRIT",):
        state = "WARN"
    
    # Check OSDs down percentage
    if down_pct >= crit_down:
        state = "CRIT"
    elif down_pct >= warn_down and state not in ("CRIT",):
        state = "WARN"
    
    # Build summary message
    summary = "OSDs: %d, Remapped PGs: %d" % (num_osds, data.get("num_remapped_pgs", 0))
    if num_out > 0:
        summary = summary + ", %d OSDs out" % num_out
    if num_down > 0:
        summary = summary + ", %d OSDs down" % num_down
    
    # Build metrics dict (only numbers, no strings)
    metrics = {
        "osds_in": num_in_osds,
        "osds_out": num_out,
        "osds_down": num_down,
        "osds_up": num_up_osds,
        "osds_total": num_osds,
        "out_percent": out_pct,
        "down_percent": down_pct,
    }
    
    return {"changed": False, "msg": summary, 
            "data": {"state": state, "metrics": metrics, "details": ""}}
