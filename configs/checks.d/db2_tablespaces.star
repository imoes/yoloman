def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/db2_tablespaces"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 tablespace entries",
                    "data": {"discovery": []}}
        
        instances = {}
        for line in res.stdout.splitlines():
            stripped = line.strip()
            if stripped.startswith("[[[") and stripped.endswith("]]]"):
                instance = stripped[3:-3]
                if instance not in instances:
                    instances[instance] = True
        
        discovery = []
        for instance in instances:
            discovery.append({"item": instance + ".",
                              "params": {"levels": (10.0, 5.0), "magic_normsize": 1000},
                              "metrics": ["tablespace_size", "tablespace_used", "tablespace_max_size"]})
        
        return {"changed": False, "msg": "discovered %d DB2 instances" % len(discovery),
                "data": {"discovery": discovery}}
    
    # Check mode
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    parts = item.split(".", 1)
    if len(parts) != 2:
        return {"changed": False, "msg": "Invalid check item given (must be <instance>.<tablespace>)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    instance = parts[0]
    tbsname = parts[1]
    
    res = ctx.run(["cat", "/proc/db2_tablespaces"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "Failed to read DB2 tablespace data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse DB2 agent output
    current_instance = None
    dbs = {}
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith("[[[") and stripped.endswith("]]]"):
            current_instance = stripped[3:-3]
            dbs[current_instance] = []
        elif current_instance:
            dbs[current_instance].append(line.split())
    
    db = dbs.get(instance)
    if not db:
        return {"changed": False, "msg": "Instance %s not found" % instance,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # First row is headers, rest are tablespace entries
    if len(db) < 2:
        return {"changed": False, "msg": "No tablespace entries found for instance %s" % instance,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    headers = db[0]
    db_tables = {x[0]: x[1:] for x in db[1:]}
    tablespace = db_tables.get(tbsname)
    
    if not tablespace:
        return {"changed": False, "msg": "Tablespace %s not found for instance %s" % (tbsname, instance),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Check for required headers
    if "TBSP_TYPE" not in headers or "TBSP_STATE" not in headers or "TBSP_USABLE_SIZE_KB" not in headers or "TBSP_TOTAL_SIZE_KB" not in headers or "TBSP_USED_SIZE_KB" not in headers or "TBSP_FREE_SIZE_KB" not in headers:
        return {"changed": False, "msg": "Missing required headers in tablespace data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Map headers to indices and values
    tbsp_type = tablespace[headers.index("TBSP_TYPE")]
    tbsp_state = tablespace[headers.index("TBSP_STATE")]
    tbsp_usable_str = tablespace[headers.index("TBSP_USABLE_SIZE_KB")]
    tbsp_total_str = tablespace[headers.index("TBSP_TOTAL_SIZE_KB")]
    tbsp_used_str = tablespace[headers.index("TBSP_USED_SIZE_KB")]
    tbsp_free_str = tablespace[headers.index("TBSP_FREE_SIZE_KB")]
    
    # Parse numeric values safely
    tbsp_usable = float(tbsp_usable_str) * 1024 if tbsp_usable_str.isdigit() else 0.0
    tbsp_total = float(tbsp_total_str) * 1024 if tbsp_total_str.isdigit() else 0.0
    tbsp_used = float(tbsp_used_str) * 1024 if tbsp_used_str.isdigit() else 0.0
    tbsp_free = float(tbsp_free_str) * 1024 if tbsp_free_str.isdigit() else 0.0
    
    # For SMS type, usable = free
    usable = tbsp_free if tbsp_type == "SMS" else tbsp_usable
    
    # Thresholds from params
    warn_mb, crit_mb = params.get("levels", (10.0, 5.0))
    warn_bytes = warn_mb * 1024 * 1024
    crit_bytes = crit_mb * 1024 * 1024
    
    # Calculate free space
    free_bytes = usable - tbsp_used
    abs_free = free_bytes
    perc_free = (free_bytes / usable * 100.0) if usable > 0 else 0.0
    
    # Determine state based on free space thresholds
    state = "OK"
    levels_text = "warn at %f MB, crit at %f MB" % (warn_mb, crit_mb) if (warn_mb > 0 or crit_mb > 0) else "no levels set"
    infotext = "%f%% free" % perc_free
    
    if crit_bytes > 0 and abs_free <= crit_bytes:
        state = "CRIT"
    elif warn_bytes > 0 and abs_free <= warn_bytes:
        state = "WARN"
    
    if state != "OK":
        value_str = "%f MB" % (free_bytes / (1024*1024))
        infotext = "only %s left %s" % (value_str, levels_text)
    
    # Build metrics dict
    metrics = {
        "tablespace_size": usable,
        "tablespace_used": tbsp_used,
        "tablespace_max_size": tbsp_total,
    }
    
    # Add levels info
    levels_warn = max(0.0, tbsp_total - warn_bytes)
    levels_crit = max(0.0, tbsp_total - crit_bytes)
    metrics["tablespace_size_levels"] = [levels_warn, levels_crit]
    
    # Final message
    msg = "%f MB of %f MB used, %f%% free" % (
        tbsp_used / (1024*1024),
        usable / (1024*1024),
        perc_free
    )
    
    msg += ", State: %s" % tbsp_state
    msg += ", Type: %s" % tbsp_type
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}
