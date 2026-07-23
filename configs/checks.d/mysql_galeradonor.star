def main(ctx, params):
    # Determine if this is discovery mode
    if params.get("_discover"):
        # Run mysql command to get status variables
        res = ctx.run(["mysql", "-N", "-e", "SHOW STATUS; SHOW VARIABLES LIKE 'wsrep_provider'; SHOW VARIABLES LIKE 'wsrep_sst_donor'; SHOW VARIABLES LIKE 'wsrep_cluster_address'; SHOW VARIABLES LIKE 'wsrep_cluster_size'; SHOW VARIABLES LIKE 'wsrep_cluster_status'; SHOW VARIABLES LIKE 'version';"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "MySQL command failed", "data": {"discovery": []}}
        
        # Parse output: mysql returns lines in format "Variable_name	value" for SHOW VARIABLES
        # and "Variable_name	value" for SHOW STATUS
        lines = res.stdout.splitlines()
        data = {}
        current_section = "mysql"
        
        for line in lines:
            parts = line.split("\t", 1)
            if len(parts) == 2:
                name, value = parts
                if name == "wsrep_provider":
                    data["wsrep_provider"] = value
                elif name == "wsrep_sst_donor":
                    data["wsrep_sst_donor"] = value
                elif name == "wsrep_cluster_address":
                    data["wsrep_cluster_address"] = value
                elif name == "wsrep_cluster_size":
                    data["wsrep_cluster_size"] = value
                elif name == "wsrep_cluster_status":
                    data["wsrep_cluster_status"] = value
                elif name == "version":
                    data["version"] = value
        
        # Check if we have Galera provider and wsrep_sst_donor (required for discovery)
        has_provider = data.get("wsrep_provider") and data.get("wsrep_provider") != "none"
        has_donor = "wsrep_sst_donor" in data
        
        if has_provider and has_donor:
            return {
                "changed": False,
                "msg": "discovered 1 Galera donor instance",
                "data": {
                    "discovery": [{
                        "item": "mysql",
                        "params": {"wsrep_sst_donor": data["wsrep_sst_donor"]},
                        "metrics": []
                    }]
                }
            }
        else:
            return {"changed": False, "msg": "discovered 0 Galera donor instances", "data": {"discovery": []}}
    
    # Check mode: single instance
    item = params.get("item", "mysql")
    
    # Run mysql command to get required variables
    res = ctx.run(["mysql", "-N", "-e", "SHOW VARIABLES LIKE 'wsrep_sst_donor'; SHOW VARIABLES LIKE 'wsrep_provider';"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "MySQL command failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse output
    lines = res.stdout.splitlines()
    data = {}
    for line in lines:
        parts = line.split("\t", 1)
        if len(parts) == 2:
            name, value = parts
            if name == "wsrep_sst_donor":
                data["wsrep_sst_donor"] = value
            elif name == "wsrep_provider":
                data["wsrep_provider"] = value
    
    # Check prerequisites
    has_provider = data.get("wsrep_provider") and data.get("wsrep_provider") != "none"
    wsrep_sst_donor = data.get("wsrep_sst_donor")
    
    if not has_provider or wsrep_sst_donor == None:
        return {
            "changed": False,
            "msg": "Galera donor information is missing",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Compare with expected value from discovery
    expected_donor = params.get("wsrep_sst_donor", "")
    infotext = "WSREP SST donor: %s" % wsrep_sst_donor
    
    if wsrep_sst_donor != expected_donor:
        infotext += " (at discovery: %s)" % expected_donor
    
    # Determine state
    if wsrep_sst_donor == expected_donor:
        state = "OK"
    else:
        state = "WARN"
    
    return {
        "changed": False,
        "msg": infotext,
        "data": {
            "state": state,
            "metrics": {},
            "details": ""
        }
    }