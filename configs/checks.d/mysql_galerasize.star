def main(ctx, params):
    if params.get("_discover"):
        # Run mysql command to get status variables
        res = ctx.run(["mysql", "-N", "-e", "SHOW GLOBAL STATUS; SHOW GLOBAL VARIABLES LIKE 'wsrep_%'; SHOW VARIABLES LIKE 'version';"], mutates=False)
        if res.rc != 0:
            # MySQL not available - return empty discovery
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        
        # Parse output into sections by instance
        sections = {}
        current_section = "mysql"
        for line in res.stdout.splitlines():
            if line.startswith("[[") and line.endswith("]]"):
                current_section = line.strip("[ ]")
                continue
            parts = line.split("\t", 1)
            if len(parts) == 2:
                key, value = parts
                if key.startswith("wsrep_"):
                    # Only collect Galera-related metrics for Galera check
                    sections.setdefault(current_section, {})[key] = value
                elif key == "version":
                    sections.setdefault(current_section, {})[key] = value
        
        # Discovery: for each instance with wsrep_provider set (not "none") and wsrep_cluster_size present
        out = []
        for instance, data in sections.items():
            wsrep_provider = data.get("wsrep_provider")
            has_provider = wsrep_provider != None and wsrep_provider != "none"
            if has_provider and "wsrep_cluster_size" in data:
                out.append({
                    "item": instance,
                    "params": {"invsize": data["wsrep_cluster_size"]},
                    "metrics": ["wsrep_cluster_size"]
                })
        
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}
    
    # Check mode for single item
    item = params.get("item", "")
    
    # Run mysql command to get status variables
    res = ctx.run(["mysql", "-N", "-e", "SHOW GLOBAL STATUS; SHOW GLOBAL VARIABLES LIKE 'wsrep_%';"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "MySQL query failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "Cannot connect to MySQL"}}
    
    # Parse output into section
    section = {}
    for line in res.stdout.splitlines():
        parts = line.split("\t", 1)
        if len(parts) == 2:
            key, value = parts
            if key.startswith("wsrep_"):
                section[key] = value
    
    # Check if item exists
    wsrep_cluster_size = section.get("wsrep_cluster_size")
    if wsrep_cluster_size == None:
        return {"changed": False, "msg": "Galera cluster size information missing",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": "wsrep_cluster_size not found"}}
    
    # Get expected size from discovery
    expected_size = params.get("invsize", wsrep_cluster_size)
    
    # Compare
    state = "OK"
    infotext = "WSREP cluster size: %s" % wsrep_cluster_size
    
    if wsrep_cluster_size != expected_size:
        state = "CRIT"
        infotext += " (at discovery: %s)" % expected_size
    
    return {"changed": False, "msg": infotext,
            "data": {"state": state, "metrics": {"wsrep_cluster_size": int(wsrep_cluster_size)}, "details": ""}}