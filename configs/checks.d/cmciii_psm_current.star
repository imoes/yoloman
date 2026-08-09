def _is_number(s):
    if s == None:
        return False
    if type(s) == "int" or type(s) == "float":
        return True
    s = str(s).strip()
    if len(s) == 0:
        return False
    # Allow optional leading sign, digits, at most one dot.
    body = s.lstrip("+-")
    if len(body) == 0:
        return False
    dot_seen = False
    for ch in body:
        if ch == ".":
            if dot_seen:
                return False
            dot_seen = True
        elif not (ch >= "0" and ch <= "9"):
            return False
    return True

def _to_float(v):
    if type(v) == "int" or type(v) == "float":
        return float(v)
    s = str(v).strip()
    if s == "":
        return 0.0
    # Handle leading sign.
    sign = 1.0
    rest = s
    if rest.startswith("+"):
        rest = rest[1:]
    elif rest.startswith("-"):
        sign = -1.0
        rest = rest[1:]
    parts = rest.split(".")
    whole = "0"
    frac = ""
    if len(parts) == 1:
        whole = parts[0]
    elif len(parts) == 2:
        whole = parts[0]
        frac = parts[1]
    w = 0
    for ch in whole:
        w = w * 10 + (ord(ch) - ord("0"))
    f = 0
    for ch in frac:
        f = f * 10 + (ord(ch) - ord("0"))
    scale = 1
    for _ in range(len(frac)):
        scale = scale * 10
    return sign * (float(w) + float(f) / float(scale))

def _walk_column(ctx, host, community, version, base, col_oid):
    full = base + col_oid
    res = ctx.run(["snmpwalk", "-v" + version, "-c", community, "-Oqn", host, full], mutates=False)
    rows = {}
    if res.rc != 0:
        return rows
    for line in res.stdout.splitlines():
        sp = line.find(" ")
        if sp == -1:
            continue
        oid = line[:sp]
        val = line[sp + 1:]
        idx = oid[len(full) + 1:]
        rows[idx] = val
    return rows

def _get_scalar(ctx, host, community, version, oid):
    res = ctx.run(["snmpget", "-v" + version, "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc != 0:
        return ""
    return res.stdout.strip()

def _gather_sensors(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")
    base = "1.3.6.1.4.1.2606.7.4.2.2.1.3.2"
    DESCNAME = ".1"
    VALUE = ".2"
    STATUS = ".3"
    UNITSTYPE = ".4"
    SERIAL = ".5"
    POSITION = ".6"
    SETPTHIGH = ".7"  # min current
    SETPTLOW = ".8"   # max current
    LOCATION = ".9"
    INDEXCOL = ".10"

    sys_descr = _get_scalar(ctx, host, community, version, "1.3.6.1.2.1.1.1.0")
    if sys_descr == "":
        return {}
    if not (sys_descr.startswith("Rittal") or sys_descr.startswith("LCP")):
        return {}

    values = _walk_column(ctx, host, community, version, base, VALUE)
    sensors = {}
    for idx in values:
        sensors[idx] = {
            "DescName": _get_scalar(ctx, host, community, version, base + DESCNAME + "." + idx),
            "Value": values[idx],
            "Status": _get_scalar(ctx, host, community, version, base + STATUS + "." + idx),
            "Unit Type": _get_scalar(ctx, host, community, version, base + UNITSTYPE + "." + idx),
            "Serial Number": _get_scalar(ctx, host, community, version, base + SERIAL + "." + idx),
            "Mounting Position": _get_scalar(ctx, host, community, version, base + POSITION + "." + idx),
            "SetPtHighAlarm": _get_scalar(ctx, host, community, version, base + SETPTHIGH + "." + idx),
            "SetPtLowAlarm": _get_scalar(ctx, host, community, version, base + SETPTLOW + "." + idx),
            "_location_": _get_scalar(ctx, host, community, version, base + LOCATION + "." + idx),
            "_index_": _get_scalar(ctx, host, community, version, base + INDEXCOL + "." + idx),
        }
    return sensors

def main(ctx, params):
    if params.get("_discover"):
        sensors = _gather_sensors(ctx, params)
        if not sensors:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        use_desc = params.get("use_sensor_description", False)
        out = []
        for id_ in sensors:
            entry = sensors[id_]
            if use_desc:
                loc = entry.get("_location_", "")
                idx = entry.get("_index_", "")
                desc = entry.get("DescName", "")
                item = "%s-%s %s" % (loc, idx, desc)
            else:
                item = id_
            out.append({"item": item, "params": {"_item_key": id_}, "metrics": ["current"]})
        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out}}

    item = params.get("item", "")
    item_key = params.get("_item_key")
    sensors = _gather_sensors(ctx, params)
    if not sensors:
        return {"changed": False, "msg": "Rittal CMCIII/LCP device not present on host",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    entry = None
    if item_key:
        entry = sensors.get(item_key)
    if entry == None:
        entry = sensors.get(item)
    if entry == None:
        return {"changed": False, "msg": "no such sensor: " + str(item),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    value = entry.get("Value", "")
    min_current = entry.get("SetPtHighAlarm", "")
    max_current = entry.get("SetPtLowAlarm", "")
    status = entry.get("Status", "")

    if _is_number(value):
        current = _to_float(value)
    else:
        current = 0.0

    if status == "OK":
        state = "OK"
    else:
        state = "CRIT"

    warn = params.get("warn", None)
    crit = params.get("crit", None)
    if warn != None and crit != None and _is_number(warn) and _is_number(crit):
        w = _to_float(warn)
        c = _to_float(crit)
        if current >= c:
            state = "CRIT"
        elif current >= w:
            state = "WARN"
    elif crit != None and _is_number(crit):
        c = _to_float(crit)
        if current >= c:
            state = "CRIT"

    metrics = {"current": current}
    summary = "Current: %s (%s/%s)" % (str(value), str(min_current), str(max_current))
    details = "Type: %s\nSerial: %s\nPosition: %s" % (
        str(entry.get("Unit Type", "")),
        str(entry.get("Serial Number", "")),
        str(entry.get("Mounting Position", "")),
    )

    return {"changed": False, "msg": summary, "data": {"state": state, "metrics": metrics, "details": details}}