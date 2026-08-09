SYSOID_OID = ".1.3.6.1.2.1.1.2.0"

MODEL_21501_TEMP_OIDS = {
    "Ambient 1": ".1.3.6.1.4.1.34187.21501.2.1.245970000",
    "Ambient 2": ".1.3.6.1.4.1.34187.21501.2.1.246110000",
}

MODEL_74195_TEMP_OIDS = {
    "Ambient 1": ".1.3.6.1.4.1.34187.74195.2.1.245960000",
    "Ambient 2": ".1.3.6.1.4.1.34187.74195.2.1.246080000",
}

def _is_number_str(s):
    if not s:
        return False
    dot_seen = False
    for ch in s:
        if ch == ".":
            if dot_seen:
                return False
            dot_seen = True
        elif ch < "0" or ch > "9":
            return False
    return True

def _snmp_walk_first_value(ctx, community, host, oid):
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-On", host, oid],
        mutates=False,
        ok_codes=[0, 1],
    )
    if res.rc != 0 or not res.stdout.strip():
        return None
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        eq_pos = line.find(" = ")
        if eq_pos < 0:
            continue
        rest = line[eq_pos + 3:]
        colon_pos = rest.find(": ")
        if colon_pos >= 0:
            return rest[colon_pos + 2:].strip()
        return rest.strip()
    return None

def _detect_model(ctx, community, host):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, SYSOID_OID],
        mutates=False,
        ok_codes=[0, 1],
    )
    if res.rc != 0 or not res.stdout.strip():
        return None
    val = res.stdout.strip()
    if "34187.21501" in val:
        return "21501"
    if "34187.74195" in val:
        return "74195"
    return None

def _parse_temp(raw):
    if raw == None:
        return None
    v = raw.strip()
    is_neg = v.startswith("-")
    check_v = v[1:] if is_neg else v
    if not _is_number_str(check_v):
        return None
    return float(v)

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        model = _detect_model(ctx, community, host)
        if model == None:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        discovery = [
            {"item": "Ambient 1", "params": {"warn": 30.0, "crit": 35.0},
             "metrics": ["temp"]},
            {"item": "Ambient 2", "params": {"warn": 30.0, "crit": 35.0},
             "metrics": ["temp"]},
        ]
        return {"changed": False, "msg": "discovered 2 items",
                "data": {"discovery": discovery}}

    item = params.get("item", "Ambient 1")
    if not item.startswith("Ambient"):
        item = "Ambient " + item

    if item != "Ambient 1" and item != "Ambient 2":
        return {"changed": False, "msg": "unknown item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    model = _detect_model(ctx, community, host)
    if model == None:
        return {"changed": False,
                "msg": "device not identified as Wagner Titanus TopSense",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    oid_map = MODEL_21501_TEMP_OIDS if model == "21501" else MODEL_74195_TEMP_OIDS
    oid = oid_map.get(item)
    if oid == None:
        return {"changed": False, "msg": "no OID mapped for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    raw = _snmp_walk_first_value(ctx, community, host, oid)
    temp = _parse_temp(raw)
    if temp == None:
        raw_label = raw if raw != None else "<no response>"
        return {"changed": False,
                "msg": "cannot parse temperature for " + item + ": " + raw_label,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    warn = params.get("warn", 30.0)
    crit = params.get("crit", 35.0)

    if temp >= crit:
        state = "CRIT"
    elif temp >= warn:
        state = "WARN"
    else:
        state = "OK"

    msg = "%s: %f C" % (item, temp)
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"temp": temp}, "details": ""}}