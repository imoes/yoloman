# Module-level constants (defined before use)
# OID tree for extreme_vsp_switches_temperature
_BASE_OID = ".1.3.6.1.4.1.2272.1.101.1.1"
_OID_DESCRIPTION = _BASE_OID + ".2.1.2"
_OID_TEMP = _BASE_OID + ".2.1.3"

# Detect NetExtreme: check if sysObjectID starts with known OIDs
def _is_netExtreme(ctx, community, host):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc != 0:
        return False
    line = res.stdout.strip()
    idx = line.find(" = OID: ")
    if idx == -1:
        idx = line.find(" = ")
        if idx != -1:
            idx = idx + 3
    else:
        idx = idx + 8
    if idx == -1 or idx >= len(line):
        return False
    sysoid = line[idx:].strip()
    return (sysoid.startswith(".1.3.6.1.4.1.1916.2") or
            sysoid.startswith(".1.3.6.1.4.1.2272.2"))


def _discover_items(ctx, community, host):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, _OID_TEMP], mutates=False)
    if res.rc != 0:
        return []
    
    items = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        if not oid_part.startswith(_OID_TEMP + "."):
            continue
        idx_str = oid_part[len(_OID_TEMP) + 1:]
        if not idx_str.isdigit():
            continue
        idx = int(idx_str)
        
        desc_oid = "%s.%d" % (_OID_DESCRIPTION, idx)
        res_desc = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, desc_oid], mutates=False)
        if res_desc.rc != 0:
            continue
        desc_line = res_desc.stdout.strip()
        desc_idx = desc_line.find("=")
        if desc_idx == -1:
            continue
        desc_val = desc_line[desc_idx+1:].strip()
        
        temp_oid = "%s.%d" % (_OID_TEMP, idx)
        res_temp = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, temp_oid], mutates=False)
        if res_temp.rc != 0:
            continue
        temp_line = res_temp.stdout.strip()
        temp_idx = temp_line.find("=")
        if temp_idx == -1:
            continue
        temp_val = temp_line[temp_idx+1:].strip()
        if not temp_val:
            continue
        temp = float(temp_val)
        items.append({"item": desc_val, "params": {"levels": (50.0, 60.0)},
                      "metrics": ["temperature"]})
    return items


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    # Discovery mode
    if params.get("_discover"):
        if not _is_netExtreme(ctx, community, host):
            return {"changed": False, "msg": "not a NetExtreme device",
                    "data": {"discovery": []}}
        items = _discover_items(ctx, community, host)
        return {"changed": False, "msg": "discovered %d sensors" % len(items),
                "data": {"discovery": items}}
    
    # Check mode: process one item
    item = params.get("item", "")
    warn, crit = params.get("levels", (50.0, 60.0))
    
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, _OID_TEMP], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP error",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    temp_map = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        parts = line.split("=", 1)
        if len(parts) != 2:
            continue
        oid_part = parts[0].strip()
        value_part = parts[1].strip()
        if not oid_part.startswith(_OID_TEMP + "."):
            continue
        idx_str = oid_part[len(_OID_TEMP) + 1:]
        if not idx_str.isdigit():
            continue
        idx = int(idx_str)
        
        desc_oid = "%s.%d" % (_OID_DESCRIPTION, idx)
        res_desc = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, desc_oid], mutates=False)
        if res_desc.rc != 0:
            continue
        desc_line = res_desc.stdout.strip()
        desc_idx = desc_line.find("=")
        if desc_idx == -1:
            continue
        desc_val = desc_line[desc_idx+1:].strip()
        
        temp_oid = "%s.%d" % (_OID_TEMP, idx)
        res_temp = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, temp_oid], mutates=False)
        if res_temp.rc != 0:
            continue
        temp_line = res_temp.stdout.strip()
        temp_idx = temp_line.find("=")
        if temp_idx == -1:
            continue
        temp_val = temp_line[temp_idx+1:].strip()
        if not temp_val:
            continue
        temp = float(temp_val)
        temp_map[desc_val] = temp
    
    if item not in temp_map:
        return {"changed": False, "msg": "sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    temp = temp_map[item]
    
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"
    else:
        state = "OK"
    
    msg = "%s: %f C" % (item, temp)
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"temperature": temp}, "details": ""}}
