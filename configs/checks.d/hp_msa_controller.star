def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    if params.get("_discover"):
        # Walk the controller index column to discover controllers
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", "-On", host, ".1.3.6.1.4.1.23867.1.2.1.4.1"], mutates=False)
        if res.rc == 127:
            return {"changed": False, "msg": "snmpwalk not found", "data": {"discovery": []}}
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP query failed: " + res.stderr, "data": {"discovery": []}}
        
        discovery = []
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            index = oid[len(".1.3.6.1.4.1.23867.1.2.1.4.1") + 1:]
            if not index:
                continue
            discovery.append({"item": index, "params": {"levels": (80.0, 90.0)}, "metrics": ["cpu_util"]})
        
        return {"changed": False, "msg": "discovered %d controllers" % len(discovery), "data": {"discovery": discovery}}
    
    item = params.get("item", "")
    # Read CPU load for this controller
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.23867.1.2.1.4.2." + item], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "snmpget not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0:
        return {"changed": False, "msg": "controller %s not found or SNMP error" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr}}
    
    cpu_load = float(res.stdout.strip())
    levels = params.get("levels", (80.0, 90.0))
    warn = levels[0] if type(levels) == "tuple" else 80.0
    crit = levels[1] if type(levels) == "tuple" else 90.0
    
    if cpu_load >= crit:
        state = "CRIT"
    elif cpu_load >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    return {"changed": False, "msg": "CPU Utilization %s: %f%%" % (item, cpu_load), "data": {"state": state, "metrics": {"cpu_util": cpu_load}, "details": ""}}