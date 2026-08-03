BASE_OID = "1.3.6.1.4.1.5951.4.1.1.56.1.1"
COL_KEYNAME = BASE_OID + ".1"
COL_DAYSLEFT = BASE_OID + ".5"

def _int(x):
    x = str(x).strip()
    if x.isdigit() or (x.startswith("-") and x[1:].isdigit()):
        return int(x)
    return None

def _parse_walk(res):
    out = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        val = line[sp + 1:].strip()
        if not oid.startswith(COL_KEYNAME + "."):
            continue
        certname = val
        index = oid[len(COL_KEYNAME) + 1:]
        if not certname:
            continue
        out[certname] = index
    return out

def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        names_res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqv", host, COL_KEYNAME], mutates=False)
        if names_res.rc == 127:
            return {"changed": False, "msg": "snmpwalk not installed", "data": {"discovery": [], "host_labels": {}}}
        if names_res.rc != 0 and not names_res.stdout:
            return {"changed": False, "msg": "snmpwalk failed", "data": {"discovery": [], "host_labels": {}}}
        names = []
        for line in names_res.stdout.splitlines():
            v = line.strip()
            if v.startswith("STRING:"):
                v = v[len("STRING:"):]
            names.append(v.strip())
        if not names:
            return {"changed": False, "msg": "no netscaler ssl certificates found", "data": {"discovery": [], "host_labels": {}}}
        indices = _parse_walk(names_res)
        discovery = []
        for name in names:
            if name:
                discovery.append({"item": name, "params": {"age_levels": params.get("age_levels", [30, 10])}, "metrics": ["daysleft"]})
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery, "host_labels": {}}}
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    get_idx = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, COL_KEYNAME], mutates=False)
    if get_idx.rc == 127:
        return {"changed": False, "msg": "snmpget not installed", "data": {"state": "UNKNOWN", "metrics": {}, "details": "", "msg_detail": "snmpget not installed"}}
    get_days = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, COL_DAYSLEFT], mutates=False)
    if get_days.rc == 127:
        return {"changed": False, "msg": "snmpget not installed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if get_idx.rc != 0 or get_days.rc != 0:
        return {"changed": False, "msg": "snmp query failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    idx_res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqv", host, COL_KEYNAME], mutates=False)
    days_res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqv", host, COL_DAYSLEFT], mutates=False)
    if idx_res.rc != 0 or days_res.rc != 0:
        return {"changed": False, "msg": "snmpwalk failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    names_map = _parse_walk(idx_res)
    days_map = {}
    for line in days_res.stdout.splitlines():
        if not line.strip():
            continue
        sp = line.find(" ")
        if sp < 0:
            continue
        oid = line[:sp]
        val = line[sp + 1:].strip()
        if not oid.startswith(COL_DAYSLEFT + "."):
            continue
        index = oid[len(COL_DAYSLEFT) + 1:]
        days_map[index] = _int(val)
    target_idx = names_map.get(item)
    if target_idx == None:
        return {"changed": False, "msg": "certificate %s not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    daysleft = days_map.get(target_idx)
    if daysleft == None:
        return {"changed": False, "msg": "daysleft not found for %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    levels = params.get("age_levels", [30, 10])
    warn = levels[0] if len(levels) > 0 else 30
    crit = levels[1] if len(levels) > 1 else 10
    if daysleft <= crit:
        state = "CRIT"
    elif daysleft <= warn:
        state = "WARN"
    else:
        state = "OK"
    render = str(daysleft) + " days"
    msg = "certificate valid for " + render
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {"daysleft": daysleft}, "details": "", "msg_detail": msg}}