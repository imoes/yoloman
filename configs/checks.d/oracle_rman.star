def main(ctx, params):
    # Read the oracle_rman section from the agent
    res = ctx.run(["cat", "/var/lib/dpkg/info/oracle-rman.list"], mutates=False)
    # If the agent section is not available, return UNKNOWN
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "Oracle RMAN agent section not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse the agent output manually (we cannot assume cmk is available)
    section = {}
    lines = res.stdout.splitlines()
    for line in lines:
        if not line.strip():
            continue
        parts = line.split("|")
        if len(parts) != 6 and len(parts) != 8:
            continue
        
        sid = parts[0]
        status = parts[1]
        backupage_str = parts[5]
        
        # Safely convert backupage
        backupage = int(backupage_str) if backupage_str.isdigit() else None
        if backupage != None and backupage < 0:
            backupage = 0
        
        if len(parts) == 6:
            backuptype = parts[4]
            backuplevel = "-1"
            item = "%s.%s" % (sid, backuptype)
            backupscn = -1
        elif len(parts) == 8:
            backuptype = parts[4]
            backuplevel = parts[5]
            backupscn_str = parts[7]
            backupscn = int(backupscn_str) if backupscn_str.isdigit() else -1
            
            if backuptype == "DB_INCR":
                item = "%s.%s_%s" % (sid, backuptype, backuplevel)
            else:
                item = "%s.%s" % (sid, backuptype)
        
        section[item] = {
            "sid": sid,
            "backuptype": backuptype,
            "backuplevel": backuplevel,
            "backupage": backupage,
            "status": status,
            "backupscn": backupscn,
            "used_incr_0": False,
        }

    # Discovery mode
    if params.get("_discover"):
        discovery_list = []
        for elem in section.values():
            sid = elem["sid"]
            backuptype = elem["backuptype"]
            backuplevel = elem["backuplevel"]
            
            if backuptype in ("ARCHIVELOG", "DB_FULL", "DB_INCR", "CONTROLFILE"):
                if backuptype == "DB_INCR":
                    item = "%s.%s_%s" % (sid, backuptype, backuplevel)
                else:
                    item = "%s.%s" % (sid, backuptype)
                
                discovery_list.append({
                    "item": item,
                    "params": {"levels": [None, None]},
                    "metrics": ["age"] if elem["status"] in ("COMPLETED", "COMPLETED WITH WARNINGS") else [],
                })
        
        return {
            "changed": False,
            "msg": "discovered %d RMAN backups" % len(discovery_list),
            "data": {"discovery": discovery_list},
        }

    # Check mode
    item = params.get("item", "")
    rman_backup = section.get(item)
    
    sid_level0 = ""
    
    if not rman_backup:
        # Check if it's DB_INCR_1 and DB_INCR_0 exists instead
        if item.endswith("1"):
            sid_level0 = item[:-1] + "0"
            if sid_level0 in section:
                rman_backup = section[sid_level0]
                rman_backup.update({"used_incr_0": True})
        
        if not rman_backup:
            return {
                "changed": False,
                "msg": "Backup item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
    
    status = rman_backup["status"]
    backupage = rman_backup["backupage"]
    backupscn = rman_backup["backupscn"]
    
    # Apply thresholds
    warn, crit = params.get("levels", (None, None))
    
    # Determine state
    state = "CRIT" if status not in ("COMPLETED", "COMPLETED WITH WARNINGS") else "OK"
    msg_parts = []
    metrics = {}
    
    if status not in ("COMPLETED", "COMPLETED WITH WARNINGS"):
        msg_parts.append("no COMPLETED backup found in last 14 days")
    elif backupage == None:
        state = "UNKNOWN"
        msg_parts.append("Unknown backupage in check found. Please update agent.")
    else:
        # Convert minutes to seconds for check_levels
        backupage_seconds = backupage * 60
        # Check levels if provided
        if crit != None and backupage_seconds >= crit:
            state = "CRIT"
        elif warn != None and backupage_seconds >= warn:
            state = "WARN"
        
        # Build message
        if backupage_seconds < 60:
            age_str = "%d seconds" % backupage_seconds
        elif backupage_seconds < 3600:
            age_str = "%d min" % (backupage_seconds // 60)
        else:
            hours = backupage_seconds // 3600
            minutes = (backupage_seconds % 3600) // 60
            age_str = "%d h %d min" % (hours, minutes)
        
        msg_parts.append("Time since last backup: " + age_str)
        metrics["age"] = backupage_seconds
    
    if backupscn > 0:
        msg_parts.append("Incremental SCN %i" % backupscn)
    
    if rman_backup["used_incr_0"]:
        msg_parts.append("Last DB_INCR_0 used")
    
    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {"state": state, "metrics": metrics, "details": ""},
    }