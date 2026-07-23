def main(ctx, params):
    if params.get("_discover"):
        # Discover DB2 databases
        res = ctx.run(["db2", "list", "db", "directory"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 databases", "data": {"discovery": []}}
        
        db_names = []
        lines = res.stdout.splitlines()
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("Database name ="):
                parts = stripped.split("=", 1)
                if len(parts) == 2:
                    db_names.append(parts[1].strip())
        
        if not db_names:
            return {"changed": False, "msg": "discovered 0 databases", "data": {"discovery": []}}
        
        discovery_items = []
        for db_name in db_names:
            res_log = ctx.run(["db2pd", "-db", db_name, "-logs"], mutates=False)
            if res_log.rc != 0:
                continue
            
            log_lines = res_log.stdout.splitlines()
            found_log_info = False
            for line in log_lines:
                stripped = line.strip()
                if "Log file size" in stripped and "=" in stripped:
                    found_log_info = True
                    break
            
            if found_log_info:
                discovery_items.append({
                    "item": db_name,
                    "params": {"levels": (-20.0, -10.0)},
                    "metrics": ["used_percent"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d databases" % len(discovery_items),
            "data": {"discovery": discovery_items}
        }
    
    # Check mode
    item = params.get("item", "")
    levels = params.get("levels", (-20.0, -10.0))
    warn = levels[0]
    crit = levels[1]
    
    res = ctx.run(["db2pd", "-db", item, "-logs"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "Cannot read log info for database %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    lines = res.stdout.splitlines()
    logfilsiz = None
    logprimary = None
    logsecond = None
    
    for line in lines:
        stripped = line.strip()
        if "=" in stripped:
            key, value = stripped.split("=", 1)
            key = key.strip()
            value = value.strip()
            if key == "Log file size":
                parts = value.split()
                if parts and parts[0].isdigit():
                    logfilsiz = int(parts[0])
            elif key == "Primary logs":
                if value.isdigit():
                    logprimary = int(value)
            elif key == "Secondary logs":
                if value.isdigit():
                    logsecond = int(value)
    
    # Try to get additional config info
    res_cfg = ctx.run(["db2", "get", "db", "cfg", "for", item], mutates=False)
    if res_cfg.rc == 0:
        cfg_lines = res_cfg.stdout.splitlines()
        for line in cfg_lines:
            stripped = line.strip()
            if "=" in stripped:
                key, value = stripped.split("=", 1)
                key = key.strip()
                value = value.strip()
                if key == "Number of primary log files":
                    if value.isdigit():
                        logprimary = int(value)
                elif key == "Number of secondary log files":
                    if value.isdigit():
                        logsecond = int(value)
    
    # Get usedspace from db2pd -dbcfg
    res_dbcfg = ctx.run(["db2pd", "-db", item, "-dbcfg"], mutates=False)
    usedspace = None
    if res_dbcfg.rc == 0:
        dbcfg_lines = res_dbcfg.stdout.splitlines()
        for line in dbcfg_lines:
            stripped = line.strip()
            if "Log space used" in stripped and ":" in stripped:
                parts = stripped.split(":", 1)
                if len(parts) >= 2:
                    val_str = parts[1].strip()
                    if val_str.isdigit():
                        usedspace = int(val_str)
    
    # Validate required values
    if usedspace == None:
        return {
            "changed": False,
            "msg": "Cannot read usedspace for database %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    if logfilsiz == None or logprimary == None or logsecond == None:
        return {
            "changed": False,
            "msg": "Invalid database info for %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    total = logfilsiz * (logprimary + logsecond) * 4096
    free = total - usedspace
    total_mb = total >> 20
    free_mb = free >> 20
    
    if total == 0:
        used_percent = 100.0
    else:
        used_percent = ((total - free) * 100.0) / total
    
    free_percent = 100.0 - used_percent
    
    # Apply thresholds (levels are negative: they mean free space % threshold)
    if free_percent >= abs(warn):
        state = "OK"
    elif free_percent >= abs(crit):
        state = "WARN"
    else:
        state = "CRIT"
    
    # For timestamp, try to get current time as fallback
    timestamp = 0
    msg = "Size: %d MB, Free: %d MB (%f%%)" % (total_mb, free_mb, free_percent)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "size": total_mb,
                "free": free_mb,
                "used_percent": used_percent,
                "free_percent": free_percent
            },
            "details": ""
        }
    }