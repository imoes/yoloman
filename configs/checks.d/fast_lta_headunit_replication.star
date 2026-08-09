def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # Probe for FastLTA device via sysObjectID
    sysoid_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if sysoid_res.rc == 127 or not sysoid_res.stdout:
        return {"changed": False, "msg": "FastLTA device not found (SNMP not available)", "data": {"discovery": [], "host_labels": {}}}
    
    sysoid = sysoid_res.stdout.strip()
    if not sysoid.startswith(".1.3.6.1.4.1.8072.3.2.10"):
        return {"changed": False, "msg": "FastLTA device not found (sysObjectID does not match)", "data": {"discovery": [], "host_labels": {}}}

    # Check that FastLTA replication OIDs exist
    rep_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.27417.2.1"], mutates=False)
    if rep_res.rc != 0:
        second_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.27417.2.1.0"], mutates=False)
        if second_res.rc != 0:
            return {"changed": False, "msg": "FastLTA device not found (no replication OIDs)", "data": {"discovery": [], "host_labels": {}}}

    if params.get("_discover"):
        # Discovery: single-service check, yield one Service if data is present
        # Fetch the tree to verify it has data
        base = ".1.3.6.1.4.1.27417.2"
        oids = ["1", "2", "5"]
        fetch_args = []
        for oid in oids:
            fetch_args.append(base + "." + oid)
        
        val_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv"] + [host] + fetch_args, mutates=False)
        if val_res.rc != 0 or not val_res.stdout.strip():
            return {"changed": False, "msg": "FastLTA replication not found", "data": {"discovery": []}}
        
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}

    # Check mode: check one item (single-service, item is "")
    base = ".1.3.6.1.4.1.27417.2"
    col1 = base + ".2"
    col2 = base + ".5"
    
    mode_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, col1], mutates=False)
    rep_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, col2], mutates=False)
    
    if mode_res.rc != 0 or rep_res.rc != 0 or not mode_res.stdout.strip() or not rep_res.stdout.strip():
        return {"changed": False, "msg": "Replication status not available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    node_replication_mode = mode_res.stdout.strip()
    replication_status = rep_res.stdout.strip()
    
    head_unit_replication_map = {
        "0": "Slave",
        "1": "Master",
        "255": "standalone",
    }
    
    if replication_status == "1":
        message = "Replication is running."
        state = "OK"
    else:
        message = "Replication is not running (!!)."
        state = "CRIT"
    
    if node_replication_mode in head_unit_replication_map:
        message += " This node is %s." % head_unit_replication_map[node_replication_mode]
    else:
        message += " Replication mode of this node is %s." % node_replication_mode
    
    return {"changed": False, "msg": message, "data": {"state": state, "metrics": {}, "details": ""}}