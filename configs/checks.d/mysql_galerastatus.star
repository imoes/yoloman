def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["mysql", "-N", "-e", "SHOW VARIABLES LIKE 'wsrep_provider'; SHOW STATUS LIKE 'wsrep_local_state_comment'; SHOW STATUS LIKE 'wsrep_cluster_status';"], mutates=False)
        lines = res.stdout.splitlines()
        data = {}
        for line in lines:
            if not line.strip():
                continue
            parts = line.split("\t", 1)
            if len(parts) == 2:
                key = parts[0].strip()
                value = parts[1].strip()
                data[key] = value
        # Check if wsrep_provider is present and not 'none'
        wsrep_provider = data.get("wsrep_provider")
        if wsrep_provider == None or wsrep_provider == "none":
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        # Check for wsrep_cluster_status (required for this check)
        if "wsrep_cluster_status" not in data:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        # This is a single-service check with item "mysql"
        return {"changed": False, "msg": "discovered 1 items",
                "data": {"discovery": [
                    {"item": "mysql", "params": {}, "metrics": []}
                ]}}
    
    # Check mode (not discovery)
    res = ctx.run(["mysql", "-N", "-e", "SHOW VARIABLES LIKE 'wsrep_provider'; SHOW STATUS LIKE 'wsrep_cluster_status';"], mutates=False)
    lines = res.stdout.splitlines()
    data = {}
    for line in lines:
        if not line.strip():
            continue
        parts = line.split("\t", 1)
        if len(parts) == 2:
            key = parts[0].strip()
            value = parts[1].strip()
            # Remove 'Variable_name' and 'Value' prefixes if present
            if key.startswith("Variable_name"):
                continue
            data[key] = value
    
    wsrep_cluster_status = data.get("wsrep_cluster_status")
    if wsrep_cluster_status == None:
        return {"changed": False, "msg": "WSREP cluster status missing",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    state = "OK" if wsrep_cluster_status == "Primary" else "CRIT"
    return {"changed": False, "msg": "WSREP cluster status: %s" % wsrep_cluster_status,
            "data": {"state": state, "metrics": {}, "details": ""}}