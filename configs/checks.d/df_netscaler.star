# ===== Starlark check module for df_netscaler (read-only) =====
# Translated from Checkmk plugin cmk.plugins.netscaler.agent_based.df_netscaler
# Uses SNMP to fetch disk usage data (.1.3.6.1.4.1.5951.4.1.1.41.8.1.*)

_BASE_OID = ".1.3.6.1.4.1.5951.4.1.1.41.8.1"
_DEFAULT_LEVELS = (80.0, 90.0)
_EXCLUDED_MOUNTPOINTS = ["/dev", "/dev/shm", "/run", "/sys", "/proc"]

def _parse_snmp_table(lines):
    name_map = {}
    size_map = {}
    avail_map = {}
    
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        eq_idx = stripped.find("=")
        if eq_idx < 0:
            continue
        oid_part = stripped[:eq_idx].strip()
        value_part = stripped[eq_idx+1:].strip()
        if not value_part.startswith(":"):
            continue
        type_val = value_part[1:].strip()
        
        if not oid_part.startswith(_BASE_OID):
            continue
        suffix = oid_part[len(_BASE_OID):]
        if not suffix:
            continue
        
        segs = suffix.split(".")
        if len(segs) < 2:
            continue
        key = ".".join(segs[1:])
        
        typ = 0
        if segs[0].isdigit():
            typ = int(segs[0])
        
        if typ == 1:
            val = type_val
            if val.startswith('"') and val.endswith('"'):
                val = val[1:-1]
            name_map[key] = val
        elif typ == 2:
            clean_val = type_val
            if clean_val.startswith('-'):
                clean_val = clean_val[1:]
            if clean_val.isdigit():
                size_map[key] = int(type_val)
            else:
                size_map[key] = 0
        elif typ == 3:
            clean_val = type_val
            if clean_val.startswith('-'):
                clean_val = clean_val[1:]
            if clean_val.isdigit():
                avail_map[key] = int(type_val)
            else:
                avail_map[key] = 0
    
    result = []
    for key in name_map:
        name = name_map[key]
        size = size_map.get(key, 0)
        avail = avail_map.get(key, 0)
        result.append((name, size, avail))
    
    return result

def _compute_state(used_percent, warn, crit):
    if used_percent >= crit:
        return "CRIT"
    elif used_percent >= warn:
        return "WARN"
    else:
        return "OK"

def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, _BASE_OID], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}
        
        section = _parse_snmp_table(res.stdout.splitlines())
        items = []
        for name, size, avail in section:
            if size <= 0 or name in _EXCLUDED_MOUNTPOINTS:
                continue
            items.append({"item": name, "params": {"levels": _DEFAULT_LEVELS}, "metrics": ["used_percent"]})
        return {"changed": False, "msg": "discovered %d filesystems" % len(items), "data": {"discovery": items}}
    
    item = params.get("item", "")
    levels = params.get("levels", _DEFAULT_LEVELS)
    warn = levels[0]
    crit = levels[1]
    
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, _BASE_OID], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    section = _parse_snmp_table(res.stdout.splitlines())
    found = False
    size = 0
    avail = 0
    for name, s, a in section:
        if name == item:
            found = True
            size = s
            avail = a
            break
    
    if not found:
        return {"changed": False, "msg": "filesystem %s not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    used = size - avail
    if size <= 0:
        used_percent = 0.0
    else:
        used_percent = (float(used) / float(size)) * 100.0
    
    state = _compute_state(used_percent, warn, crit)
    return {
        "changed": False,
        "msg": "Size: %d MB, Used: %d MB (%f%%)" % (size // 1024, used // 1024, used_percent),
        "data": {"state": state, "metrics": {"used_percent": used_percent}, "details": ""}
    }