def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/check-mk-agent/informix_dbspaces"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to read informix_dbspaces section",
                    "data": {"discovery": []}}
        
        parsed = {}
        instance = None
        entry = None
        lines = res.stdout.splitlines()
        for line in lines:
            fields = line.split()
            if not fields:
                continue
            
            # Section header: [[[instance]]]
            if len(fields) == 1 and fields[0].startswith("[[[") and fields[0].endswith("]]]"):
                instance = fields[0][3:-3]
                entry = None
            elif (instance != None and
                  len(fields) > 2 and
                  fields[0] == "(expression)" and
                  fields[2] == "DBSPACE"):
                entry = {}
                ts = instance + " " + fields[1]
                if ts not in parsed:
                    parsed[ts] = []
                parsed[ts].append(entry)
            elif entry != None and len(fields) >= 2:
                key = fields[0]
                value = "".join(fields[1:])
                entry[key] = value
        
        discovery_items = []
        for ts in parsed:
            discovery_items.append({
                "item": ts,
                "params": {"levels": ("no_levels", None), "levels_perc": ("fixed", (80.0, 85.0))},
                "metrics": ["tablespace_size", "tablespace_used"]
            })
        
        return {"changed": False, "msg": "discovered %d tablespaces" % len(discovery_items),
                "data": {"discovery": discovery_items}}
    
    # Check mode
    item = params.get("item", "")
    res = ctx.run(["cat", "/var/lib/check-mk-agent/informix_dbspaces"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to read informix_dbspaces section",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse same as discovery
    parsed = {}
    instance = None
    entry = None
    lines = res.stdout.splitlines()
    for line in lines:
        fields = line.split()
        if not fields:
            continue
        
        if len(fields) == 1 and fields[0].startswith("[[[") and fields[0].endswith("]]]"):
            instance = fields[0][3:-3]
            entry = None
        elif (instance != None and
              len(fields) > 2 and
              fields[0] == "(expression)" and
              fields[2] == "DBSPACE"):
            entry = {}
            ts = instance + " " + fields[1]
            if ts not in parsed:
                parsed[ts] = []
            parsed[ts].append(entry)
        elif entry != None and len(fields) >= 2:
            key = fields[0]
            value = "".join(fields[1:])
            entry[key] = value
    
    # Get data for requested item
    if item not in parsed:
        return {"changed": False, "msg": "tablespace not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    datafiles = parsed[item]
    size = 0
    free = 0
    FLAG_BLOBSPACE = 512
    
    for entry in datafiles:
        if "pagesize" not in entry or "system_pagesize" not in entry or "nfree" not in entry or "chksize" not in entry or "chunk_flags" not in entry:
            continue
        pagesize = int(entry["pagesize"])
        system_pagesize = int(entry["system_pagesize"])
        chunk_flags = int(entry["chunk_flags"])
        nfree_pagesize = pagesize if (FLAG_BLOBSPACE & chunk_flags) else system_pagesize
        free += int(entry["nfree"]) * nfree_pagesize
        size += int(entry["chksize"]) * system_pagesize
    
    used = size - free
    levels = params.get("levels", ("no_levels", None))
    levels_perc = params.get("levels_perc", ("fixed", (80.0, 85.0)))
    
    # Convert percentage levels to absolute
    if levels_perc[0] == "fixed":
        warn_abs = levels_perc[1][0] * size / 100.0
        crit_abs = levels_perc[1][1] * size / 100.0
        levels_used = ("fixed", (warn_abs, crit_abs))
    else:
        levels_used = levels_perc
    
    # Determine state based on used space levels
    state = "OK"
    details = ""
    if levels_used[0] == "fixed":
        warn_abs, crit_abs = levels_used[1]
        if used >= crit_abs:
            state = "CRIT"
            details = "Used space %f bytes exceeds critical threshold %f bytes" % (used, crit_abs)
        elif used >= warn_abs:
            state = "WARN"
            details = "Used space %f bytes exceeds warning threshold %f bytes" % (used, warn_abs)
    
    # Determine state based on total size levels (if any)
    if state == "OK" and levels[0] == "fixed":
        warn_size, crit_size = levels[1]
        if size >= crit_size:
            state = "CRIT"
            details = "Tablespace size %f bytes exceeds critical threshold %f bytes" % (size, crit_size)
        elif size >= warn_size:
            state = "WARN"
            details = "Tablespace size %f bytes exceeds warning threshold %f bytes" % (size, warn_size)
    
    # Prepare summary message
    msg = "Data files: %d" % len(datafiles)
    msg += ", Size: %d bytes" % size
    msg += ", Used: %d bytes" % used
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "tablespace_size": size,
                "tablespace_used": used
            },
            "details": details
        }
    }