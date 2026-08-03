def main(ctx, params):
    if params.get("_discover"):
        # Probe for ARTEC device via sysObjectID and sysDescr
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        # Check sysObjectID (1.3.6.1.2.1.1.2.0)
        oid_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if oid_res.rc != 0:
            return {"changed": False, "msg": "host unreachable", "data": {"discovery": []}}
        sys_oid = oid_res.stdout.strip()
        if sys_oid != ".1.3.6.1.4.1.8072.3.2.10":
            return {"changed": False, "msg": "not an ARTEC device", "data": {"discovery": []}}
        # Check sysDescr (1.3.6.1.2.1.1.1.0) contains "version" and "serial"
        desc_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Ov", host, ".1.3.6.1.2.1.1.1.0"], mutates=False)
        if desc_res.rc != 0:
            return {"changed": False, "msg": "sysDescr unreadable", "data": {"discovery": []}}
        desc = desc_res.stdout.strip()
        # Strip leading type tag like "STRING: ..."
        desc_val = desc
        colon_idx = desc_val.find(":")
        if colon_idx >= 0:
            desc_val = desc_val[colon_idx + 1:].strip()
        # Remove surrounding quotes
        if len(desc_val) >= 2 and desc_val[0] == '"' and desc_val[-1] == '"':
            desc_val = desc_val[1:-1]
        if "version" not in desc_val or "serial" not in desc_val:
            return {"changed": False, "msg": "sysDescr does not match ARTEC pattern", "data": {"discovery": []}}
        # Verify temperature OID is reachable
        temp_oid = ".1.3.6.1.4.1.31560.3.1.1.1.48"
        temp_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, temp_oid], mutates=False)
        if temp_res.rc != 0:
            return {"changed": False, "msg": "temperature OID unreachable", "data": {"discovery": []}}
        # Single-service check with item "Disk"
        levels = params.get("levels", (36.0, 40.0))
        warn = levels[0] if isinstance(levels, (list, tuple)) and len(levels) >= 1 else 36.0
        crit = levels[1] if isinstance(levels, (list, tuple)) and len(levels) >= 2 else 40.0
        out = {"item": "Disk", "params": {"levels": [warn, crit]}, "metrics": ["temp"]}
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [out]}}
    # Check mode for the "Disk" item
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    item = params.get("item", "Disk")
    temp_oid = ".3.6.1.4.1.31560.3.1.1.1.48"
    # Wait, correct OID:
    temp_oid = ".1.3.6.1.4.1.31560.3.1.1.1.48"
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, temp_oid], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "no temperature data: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    raw = res.stdout.strip()
    # Parse the numeric temperature value
    val = 0.0
    try_parse = raw
    # Handle potential integer or float
    try_val = None
    try_val = float(raw) if (raw.replace(".", "", 1).replace("-", "", 1).isdigit() and (raw.count(".") <= 1)) else None
    if try_val == None:
        # Maybe it has a unit or is just an integer
        try_val = int(raw) if raw.lstrip("-").isdigit() else None
    if try_val == None:
        return {"changed": False, "msg": "unparseable temperature: " + raw, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    val = try_val
    levels = params.get("levels", (36.0, 40.0))
    if hasattr(levels, "__getitem__"):
        warn = levels[0] if len(levels) >= 1 else 36.0
        crit = levels[1] if len(levels) >= 2 else 40.0
    else:
        warn = 36.0
        crit = 40.0
    state = "OK"
    if val >= crit:
        state = "CRIT"
    elif val >= warn:
        state = "WARN"
    return {"changed": False, "msg": "%s temperature: %f C" % (item, val), "data": {"state": state, "metrics": {"temp": val}, "details": ""}}