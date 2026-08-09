def _parse_ap_table(tree_out):
    result = {}
    for line in tree_out.splitlines():
        space_idx = line.find(" ")
        if space_idx == 0 or space_idx == -1:
            continue
        oid = line[:space_idx]
        value = line[space_idx + 1:]
        last_dot = oid.rfind(".")
        if last_dot <= 0:
            continue
        column_oid = oid[:last_dot]
        index = oid[last_dot + 1:]
        result[(column_oid, index)] = value.strip()
    return result

def _strip_type_tag(val):
    if val == None or val == "":
        return ""
    colon = val.find(": ")
    if colon >= 0:
        return val[colon + 2:]
    return val

def _snmp_get_value(ctx, host, community, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return ""
    return res.stdout.strip()

def _snmp_walk_pairs(ctx, host, community, base_oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, base_oid], mutates=False)
    if res.rc != 0:
        return {}
    return _parse_ap_table(res.stdout)

def _is_numeric(s):
    if s == None or s == "":
        return False
    stripped = s.strip()
    if stripped == "":
        return False
    for ch in stripped:
        if not ((ch >= "0" and ch <= "9") or ch == "." or (ch == "-" and stripped.find(ch) == 0)):
            return False
    return True

def _safe_float(s):
    if not _is_numeric(s):
        return None
    return float(s.strip())

def _gather_aps(ctx, host, community):
    table2_base = ".1.3.6.1.4.1.2011.6.139.16.1.2.1"
    table1_base = ".1.3.6.1.4.1.2011.6.139.13.3.3.1"
    
    t2_raw = _snmp_walk_pairs(ctx, host, community, table2_base + ".3")
    t1_mem = _snmp_walk_pairs(ctx, host, community, table1_base + ".40")
    
    if len(t2_raw) == 0 and len(t1_mem) == 0:
        return {}
    
    ap_map = {}
    for (col, idx), val in t2_raw.items():
        if col == table2_base + ".3":
            ap_map[val] = {"index": idx, "mem": None}
    
    for ap_id, info in ap_map.items():
        for (col, idx), val in t1_mem.items():
            if col == table1_base + ".40" and info["index"] == idx:
                info["mem"] = _safe_float(val)
                break
    
    aps = {}
    for ap_id, info in ap_map.items():
        if info["mem"] != None:
            aps[ap_id] = {"mem_used": info["mem"]}
    return aps

def main(ctx, params):
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        
        sys_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if sys_res.rc != 0:
            return {"changed": False, "msg": "SNMP device not reachable", "data": {"discovery": []}}
        sys_oid = sys_res.stdout.strip()
        if sys_oid.find("2011.2.240.17") == -1:
            return {"changed": False, "msg": "Not a Huawei WLC device", "data": {"discovery": []}}
        
        aps = _gather_aps(ctx, host, community)
        if len(aps) == 0:
            return {"changed": False, "msg": "no Huawei WLC access points found", "data": {"discovery": []}}
        
        discovery = []
        for ap_id in sorted(aps.keys()):
            discovery.append({
                "item": ap_id,
                "params": {"levels": [80.0, 90.0]},
                "metrics": ["mem_used_percent"],
            })
        return {"changed": False, "msg": "discovered %d access points" % len(discovery), "data": {"discovery": discovery}}
    
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    levels = params.get("levels", [80.0, 90.0])
    warn = levels[0] if len(levels) > 0 else 80.0
    crit = levels[1] if len(levels) > 1 else 90.0
    
    aps = _gather_aps(ctx, host, community)
    if len(aps) == 0:
        return {"changed": False, "msg": "no Huawei WLC access points found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    ap = aps.get(item)
    if ap == None:
        return {"changed": False, "msg": "no such AP: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    mem = ap["mem_used"]
    state = "CRIT" if mem >= crit else ("WARN" if mem >= warn else "OK")
    is_int = mem == float(int(mem))
    used_str = "%d%%" % int(mem) if is_int else "%f%%" % mem
    return {"changed": False, "msg": "AP %s Memory used: " % item + used_str, "data": {"state": state, "metrics": {"mem_used_percent": mem}, "details": "Memory used: " + used_str}}