def _to_float(s):
    s = s.strip()
    if s == "" or s == "None":
        return 0.0
    return float(s)

def _round2(x):
    return int(x * 100 + 0.5) / 100.0

def _get_pool_index(ctx, community, host, base, item):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base + ".1"], mutates=False)
    if res.rc != 0:
        return None
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid, val = parts[0], parts[1].strip()
        suffix = oid[len(base) + 1:]
        idx_parts = suffix.split(".")
        pool_id = idx_parts[0]
        disp = val.strip().strip('"')
        if disp == item or pool_id == item:
            return pool_id
    return None

def _discover(ctx, community, host, base):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no pools discovered", "data": {"discovery": []}}
    pools = {}
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid, val = parts[0], parts[1].strip()
        suffix = oid[len(base) + 1:]
        idx_parts = suffix.split(".")
        pool_id = idx_parts[0]
        if len(idx_parts) < 2:
            continue
        col = idx_parts[1]
        if pool_id not in pools:
            pools[pool_id] = {"capacity": 0.0, "usage": 0.0, "pool_id": ""}
        if col == "1":
            pools[pool_id]["pool_id"] = val.strip().strip('"')
        elif col == "3":
            pools[pool_id]["capacity"] = _to_float(val)
        elif col == "4":
            pools[pool_id]["usage"] = _to_float(val)
    discovery = []
    for pool_id in sorted(pools.keys()):
        p = pools[pool_id]
        name = p["pool_id"] if p["pool_id"] != "" else pool_id
        discovery.append({"item": name, "params": {"warn": 90, "crit": 95}, "metrics": ["used_percent"]})
    return {"changed": False, "msg": "discovered %d pools" % len(discovery), "data": {"discovery": discovery}}

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "")
    warn = params.get("warn", 90)
    crit = params.get("crit", 95)

    sys_oid = ".1.3.6.1.2.1.1.2.0"
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, sys_oid], mutates=False)
    if res.rc == 127 or res.rc != 0:
        return {"changed": False, "msg": "SNMP not available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sys_val = res.stdout.strip()

    base_150 = ".1.3.6.1.4.1.211.1.21.1.150.14.5.2.1"
    base_153 = ".1.3.6.1.4.1.211.1.21.1.153.14.5.2.1"

    if sys_val == ".1.3.6.1.4.1.211.1.21.1.150":
        base = base_150
    elif sys_val == ".1.3.6.1.4.1.211.1.21.1.153":
        base = base_153
    else:
        return {"changed": False, "msg": "not a FJD ETERNUS device", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    if params.get("_discover"):
        return _discover(ctx, community, host, base)

    pool_index = _get_pool_index(ctx, community, host, base, item)
    if pool_index == None:
        return {"changed": False, "msg": "no such pool: %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    cap_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base + ".3." + pool_index], mutates=False)
    use_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, base + ".4." + pool_index], mutates=False)
    if cap_res.rc != 0 or use_res.rc != 0:
        return {"changed": False, "msg": "cannot read pool data: %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    capacity = _to_float(cap_res.stdout.strip())
    usage = _to_float(use_res.stdout.strip())
    if capacity == 0:
        return {"changed": False, "msg": "zero capacity pool: %s" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    available = capacity - usage
    used_percent = (usage / capacity) * 100.0
    state = "CRIT" if used_percent >= crit else ("WARN" if used_percent >= warn else "OK")
    msg = "%s: %f%% used (%s of %s free)" % (item, used_percent, str(available), str(capacity))
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {"used_percent": _round2(used_percent)}, "details": ""}}