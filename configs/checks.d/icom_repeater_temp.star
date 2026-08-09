def _snmp_get_value(ctx, host, community, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return None
    return res.stdout.strip()

def _snmp_walk(ctx, host, community, oid):
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid], mutates=False)
    if res.rc != 0:
        return []
    lines = []
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        lines.append((line[:sp], line[sp+1:].strip()))
    return lines

def _to_float(s):
    if s == None or len(s) == 0:
        return None
    # strip trailing unit char if present
    num = s
    unit = ""
    if s[-1] in ["C", "F", "c", "f"]:
        num = s[:-1]
        unit = s[-1].lower()
    else:
        # try to detect numeric prefix
        ok = True
        for ch in num:
            if not (ch in "0123456789.+-"):
                ok = False
                break
        if not ok:
            return None
    # validate num is parseable
    if num == "" or num == "." or num == "-" or num == "+" or num == "-." or num == "+.":
        return None
    valid = "0123456789.+-"
    for ch in num:
        if ch not in valid:
            return None
    # simple parse: allow at most one dot
    dot_count = num.count(".")
    if dot_count > 1:
        return None
    return float(num)

def _discover_icom(ctx, host, community):
    base = ".1.3.6.1.4.1.2021.8.1"
    # detect: sysDescr contains "fr5000"
    sys_oid = ".1.3.6.1.2.1.1.1.0"
    sysval = _snmp_get_value(ctx, host, community, sys_oid)
    if sysval == None:
        return None
    if sysval.find("fr5000") == -1:
        return None
    # walk columns 1 (index), 2 (name), 101 (value) and correlate by index
    idx_lines = _snmp_walk(ctx, host, community, base + ".1")
    name_lines = _snmp_walk(ctx, host, community, base + ".2")
    val_lines = _snmp_walk(ctx, host, community, base + ".101")
    if len(idx_lines) == 0:
        return None
    # build index -> name, index -> value
    names = {}
    vals = {}
    for oid, value in name_lines:
        suffix = oid[len(base + ".2") + 1:]
        if len(suffix) == 0:
            continue
        names[suffix] = value
    for oid, value in val_lines:
        suffix = oid[len(base + ".101") + 1:]
        if len(suffix) == 0:
            continue
        vals[suffix] = value
    # correlate: iterate over index lines, name from col 2, value from col 101
    parsed = {}
    for oid, idxval in idx_lines:
        suffix = oid[len(base + ".1") + 1:]
        if len(suffix) == 0:
            continue
        name = names.get(suffix, "")
        value = vals.get(suffix, "")
        if name == "Temperature":
            temp = _to_float(value)
            if temp != None:
                parsed["temp"] = temp
                if len(value) > 0:
                    parsed["temp_devunit"] = value[-1].lower()
        elif name == "ESN number":
            parsed["esnno"] = value
        elif name == "Repeater operation":
            parsed["repop"] = value.lower()
        elif name == "Abnormal temperature detection":
            if value == "Not detected":
                parsed["temp_devstatus"] = 0
            else:
                parsed["temp_devstatus"] = 2
    return parsed

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    
    if params.get("_discover"):
        parsed = _discover_icom(ctx, host, community)
        if parsed == None or not ("temp" in parsed):
            return {"changed": False, "msg": "no ICOM FR-5000 repeater found", "data": {"discovery": [], "host_labels": {}}}
        metrics = ["temp"]
        params_default = {"levels": [50.0, 55.0], "levels_lower": [-20.0, -25.0]}
        entry = {"item": "System", "params": params_default, "metrics": metrics}
        return {"changed": False, "msg": "discovered ICOM FR-5000 repeater temperature", "data": {"discovery": [entry], "host_labels": {}}}
    
    item = params.get("item", "")
    levels = params.get("levels")
    warn = 50.0
    crit = 55.0
    if levels != None and len(levels) >= 2:
        warn = levels[0]
        crit = levels[1]
    levels_lower = params.get("levels_lower")
    warn_lower = -20.0
    crit_lower = -25.0
    if levels_lower != None and len(levels_lower) >= 2:
        warn_lower = levels_lower[0]
        crit_lower = levels_lower[1]
    # Also support direct warn/crit params
    p_warn = params.get("warn")
    p_crit = params.get("crit")
    if p_warn != None:
        warn = p_warn
    if p_crit != None:
        crit = p_crit
    
    parsed = _discover_icom(ctx, host, community)
    if parsed == None:
        return {"changed": False, "msg": "no ICOM FR-5000 repeater found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not ("temp" in parsed):
        return {"changed": False, "msg": "no temperature data on this repeater", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    temp = parsed.get("temp")
    if temp == None:
        return {"changed": False, "msg": "temperature value unparseable", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    dev_status = parsed.get("temp_devstatus", 0)
    dev_unit = parsed.get("temp_devunit", "")
    
    # Apply thresholds: upper levels warn/crit, lower levels warn_lower/crit_lower
    # Upper: WARN if temp >= warn, CRIT if temp >= crit
    # Lower: WARN if temp <= warn_lower, CRIT if temp <= crit_lower
    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"
    elif temp <= crit_lower:
        state = "CRIT"
    elif temp <= warn_lower:
        state = "WARN"
    else:
        state = "OK"
    
    # Device status: 2 = abnormal temperature detection -> CRIT
    if dev_status == 2:
        if state == "OK":
            state = "CRIT"
    
    details = "Temperature: %f %s\nDevice status: %s\nThresholds: warn >= %f, crit >= %f, warn_lower <= %f, crit_lower <= %f" % (temp, dev_unit, "abnormal" if dev_status == 2 else "normal", warn, crit, warn_lower, crit_lower)
    
    msg = "%f %s (warn/crit %s/%s)" % (temp, dev_unit, str(warn), str(crit))
    
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {"temp": temp}, "details": details}}