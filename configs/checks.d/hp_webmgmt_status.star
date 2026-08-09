def _walk_table(ctx, host, community, base_oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_oid], mutates=False)
    if res.rc != 0 and res.rc != 1:
        return None
    rows = {}
    for line in res.stdout.splitlines():
        sp = line.split(" ", 1)
        if len(sp) < 2:
            continue
        oid = sp[0]
        value = sp[1]
        suffix = oid[len(base_oid) + 1:]
        rows[suffix] = value
    return rows

def _get_scalar(ctx, host, community, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return ""
    val = res.stdout.strip()
    if val.startswith('"') and val.endswith('"'):
        val = val[1:-1]
    return val

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")
    
    if params.get("_discover"):
        sys_oid = _get_scalar(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
        if not sys_oid.startswith(".1.3.6.1.4.1.11"):
            return {"changed": False, "msg": "not an HP device", "data": {"discovery": []}}
        
        exists_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.4.1.11.2.36.1.1.5.1.1.1"], mutates=False)
        if exists_res.rc != 0 and exists_res.rc != 1:
            if exists_res.rc == 2:
                pass
            else:
                return {"changed": False, "msg": "SNMP query failed: rc=%d" % exists_res.rc, "data": {"discovery": []}}
        else:
            if exists_res.rc == 1:
                pass
        
        health_base = ".1.3.6.1.4.1.11.2.36.1.1.5.1.1"
        health_rows = _walk_table(ctx, host, community, health_base)
        if health_rows == None:
            return {"changed": False, "msg": "failed to walk health table", "data": {"discovery": []}}
        
        if len(health_rows) == 0:
            return {"changed": False, "msg": "no HP web management status entries", "data": {"discovery": []}}
        
        out = []
        for suffix, _val in health_rows.items():
            out.append({"item": suffix, "params": {}, "metrics": []})
        
        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out}}
    
    sys_oid = _get_scalar(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
    if not sys_oid.startswith(".1.3.6.1.4.1.11"):
        return {"changed": False, "msg": "not an HP device", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    health_base = ".1.3.6.1.4.1.11.2.36.1.1.5.1.1"
    health_rows = _walk_table(ctx, host, community, health_base)
    if health_rows == None:
        return {"changed": False, "msg": "failed to walk health table", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    if not item in health_rows:
        return {"changed": False, "msg": "item not found: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    health = health_rows[item]
    
    status_map = {
        "1": ("UNKNOWN", "unknown"),
        "2": ("UNKNOWN", "unused"),
        "3": ("OK", "ok"),
        "4": ("WARN", "warning"),
        "5": ("CRIT", "critical"),
        "6": ("CRIT", "non-recoverable"),
    }
    
    if health in status_map:
        state, status_msg = status_map[health]
    else:
        state = "UNKNOWN"
        status_msg = "unknown (code %s)" % health
    
    summary = "Device status: " + status_msg
    
    model = _get_scalar(ctx, host, community, ".1.3.6.1.4.1.11.2.36.1.1.5.1.1.9.1")
    serial = _get_scalar(ctx, host, community, ".1.3.6.1.4.1.11.2.36.1.1.5.1.1.10.1")
    
    if model and serial:
        summary += " [Model: " + model + ", Serial Number: " + serial + "]"
    
    return {"changed": False, "msg": summary, "data": {"state": state, "metrics": {}, "details": ""}}