# Top-level constants and helpers
DEFAULT_AGE_LEVELS = (30, 10)

def _render_days(d):
    return str(d) + " days"

def _check_levels(daysleft, levels):
    warn, crit = levels
    if daysleft <= crit:
        return "CRIT", "certificate valid for %d days" % daysleft
    if daysleft <= warn:
        return "WARN", "certificate valid for %d days" % daysleft
    return "OK", "certificate valid for %d days" % daysleft

def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Fetch cert names from SNMP
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On", host,
            ".1.3.6.1.4.1.5951.4.1.1.56.1.1.1"
        ], mutates=False)
        
        cert_map = {}
        lines = res.stdout.splitlines() if res.stdout else []
        for line in lines:
            if " = " not in line:
                continue
            parts = line.split(" = ", 1)
            oid_part = parts[0].strip()
            value_part = parts[1].strip() if len(parts) > 1 else ""
            if not value_part.startswith("STRING: "):
                continue
            certname = value_part[8:].strip(' "')
            if not certname:
                continue
            # Extract index from OID
            oid_end = oid_part.rsplit(".", 1)[-1]
            if oid_end.isdigit():
                idx = int(oid_end)
                cert_map[idx] = certname
        
        # Fetch days left from SNMP
        res2 = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On", host,
            ".1.3.6.1.4.1.5951.4.1.1.56.1.1.5"
        ], mutates=False)
        
        days_map = {}
        lines2 = res2.stdout.splitlines() if res2.stdout else []
        for line in lines2:
            if " = " not in line:
                continue
            parts = line.split(" = ", 1)
            oid_part = parts[0].strip()
            value_part = parts[1].strip() if len(parts) > 1 else ""
            if not value_part.startswith("INTEGER: "):
                continue
            days_str = value_part[8:].strip()
            if days_str.isdigit():
                daysleft = int(days_str)
                # Extract index from OID
                oid_end = oid_part.rsplit(".", 1)[-1]
                if oid_end.isdigit():
                    idx = int(oid_end)
                    days_map[idx] = daysleft
        
        # Combine by index
        discovered = []
        for idx, certname in cert_map.items():
            daysleft = days_map.get(idx, 0)
            if certname:
                discovered.append({
                    "item": certname,
                    "params": {"age_levels": DEFAULT_AGE_LEVELS},
                    "metrics": ["daysleft"]
                })
        
        return {"changed": False, "msg": "discovered %d certificates" % len(discovered),
                "data": {"discovery": discovered}}
    
    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    levels = params.get("age_levels", DEFAULT_AGE_LEVELS)
    
    # Find certificate index by walking cert names
    name_bytes = item.encode('utf-8')
    name_len = len(name_bytes)
    oid_prefix = ".1.3.6.1.4.1.5951.4.1.1.56.1.1.1.%d" % name_len
    
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        oid_prefix
    ], mutates=False)
    
    cert_idx = None
    lines = res.stdout.splitlines() if res.stdout else []
    for line in lines:
        if " = " not in line:
            continue
        parts = line.split(" = ", 1)
        oid_part = parts[0].strip()
        value_part = parts[1].strip() if len(parts) > 1 else ""
        if not value_part.startswith("STRING: "):
            continue
        found_certname = value_part[8:].strip(' "')
        if found_certname == item:
            oid_suffix = oid_part.rsplit(".", 1)[-1]
            if oid_suffix.isdigit():
                cert_idx = int(oid_suffix)
            break
    
    if cert_idx == None:
        return {"changed": False, "msg": "certificate not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Get days left for this cert index
    res2 = ctx.run([
        "snmpget",
        "-v2c",
        "-c", community,
        "-On", host,
        ".1.3.6.1.4.1.5951.4.1.1.56.1.1.5.%d" % cert_idx
    ], mutates=False)
    
    if res2.rc != 0:
        return {"changed": False, "msg": "SNMP get failed: " + res2.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines2 = res2.stdout.splitlines() if res2.stdout else []
    if len(lines2) != 1:
        return {"changed": False, "msg": "unexpected snmpget output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    line2 = lines2[0].strip()
    if " = " not in line2:
        return {"changed": False, "msg": "unexpected snmpget format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    parts2 = line2.split(" = ", 1)
    value_part2 = parts2[1].strip() if len(parts2) > 1 else ""
    if not value_part2.startswith("INTEGER: "):
        return {"changed": False, "msg": "unexpected type, expected INTEGER",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    days_str = value_part2[8:].strip()
    if not days_str.isdigit():
        return {"changed": False, "msg": "invalid days-left value",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    daysleft = int(days_str)
    
    state, summary = _check_levels(daysleft, levels)
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {"daysleft": daysleft}, "details": ""}}