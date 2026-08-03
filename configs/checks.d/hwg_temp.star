def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx)
    return _check(ctx, params)

def _probe(ctx):
    community = params_get(ctx, "community", "public")
    host = params_get(ctx, "host", "localhost")
    # Detect HWG device presence via sysDescr
    descr = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False)
    if descr.rc != 0:
        return None
    return _walk(ctx, community, host)

def params_get(ctx, key, default):
    v = ctx.params.get(key) if hasattr(ctx, "params") else None
    return v if v != None else default

def _get_params(ctx):
    return ctx.params

def _walk(ctx, community, host):
    rows = _snmp_table(ctx, community, host, ".1.3.6.1.4.1.21796.4.1.3.1", ["1", "2", "3", "4", "7"])
    if len(rows) == 0:
        return {}
    return parse_hwg(rows)

def _snmp_table(ctx, community, host, base, col_indices):
    # Walk base.1..7 and correlate by index
    col_map = {}
    for col in col_indices:
        oid = base + "." + col
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, oid],
            mutates=False)
        if res.rc != 0:
            continue
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp < 0:
                continue
            full_oid = line[:sp]
            val = line[sp + 1:]
            idx = full_oid[len(oid):]
            if idx == "":
                continue
            col_map.setdefault(idx, {})[col] = val
    rows = []
    for idx in col_map:
        d = col_map[idx]
        row = [d.get("1", ""), d.get("2", ""), d.get("3", ""),
               d.get("4", ""), d.get("7", "")]
        rows.append(row)
    return rows

def parse_hwg(info):
    parsed = {}
    map_units = {"1": "c", "2": "f", "3": "k", "4": "%"}
    map_dev_states = {
        "0": "invalid", "1": "normal", "2": "out of range low",
        "3": "out of range high", "4": "alarm low", "5": "alarm high"}
    for row in info:
        index = row[0]
        descr = row[1]
        sensorstatus = row[2]
        current = row[3]
        unit = row[4]
        # Humidity branch
        if sensorstatus != "0" and map_units.get(unit, "") == "%":
            parsed.setdefault(index, {
                "descr": descr,
                "humidity": float(current) if current.replace(".", "", 1).isdigit() else 0.0,
                "dev_status_name": map_dev_states.get(sensorstatus, "n.a."),
                "dev_status": sensorstatus})
        else:
            tempval = None
            if _is_float(current):
                tempval = float(current)
            parsed.setdefault(index, {
                "descr": descr,
                "dev_unit": map_units.get(unit),
                "temperature": tempval,
                "dev_status_name": map_dev_states.get(sensorstatus, ""),
                "dev_status": sensorstatus})
    return parsed

def _is_float(s):
    if s == "":
        return False
    parts = s.split(".")
    if len(parts) == 1:
        return s.isdigit()
    if len(parts) == 2:
        return parts[0].isdigit() and parts[1].isdigit()
    return False

def _discover(ctx):
    section = _probe(ctx)
    if section == None:
        return {"changed": False, "msg": "no hwg device found",
                "data": {"discovery": []}}
    out = []
    for index, attrs in section.items():
        temp = attrs.get("temperature")
        status = attrs.get("dev_status_name", "")
        if temp != None and status not in ["invalid", ""]:
            warn = 30.0
            crit = 35.0
            levels = ctx.params.get("levels", (warn, crit)) if hasattr(ctx, "params") else (warn, crit)
            if levels != None and type(levels) == "list" and len(levels) == 2:
                warn = levels[0]
                crit = levels[1]
            out.append({"item": index,
                        "params": {"levels": [warn, crit]},
                        "metrics": ["temperature"]})
    return {"changed": False, "msg": "discovered %d items" % len(out),
            "data": {"discovery": out}}

def _check(ctx):
    p = ctx.params
    item = p.get("item", "")
    levels = p.get("levels", (30.0, 35.0))
    if levels == None:
        levels = (30.0, 35.0)
    warn = levels[0]
    crit = levels[1]
    community = p.get("community", "public")
    host = p.get("host", "localhost")
    section = _probe_with(ctx, community, host)
    if section == None:
        return {"changed": False, "msg": "no hwg device found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if item not in section:
        return {"changed": False, "msg": "item %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = section[item]
    status_name = data.get("dev_status_name", "")
    state_map = {"invalid": "UNKNOWN", "normal": "OK",
                 "out of range low": "CRIT", "out of range high": "CRIT",
                 "alarm low": "CRIT", "alarm high": "CRIT"}
    state = state_map.get(status_name, "UNKNOWN")
    temp = data.get("temperature")
    if temp == None:
        msg = "Status: %s" % status_name
        return {"changed": False, "msg": msg,
                "data": {"state": state, "metrics": {}, "details": msg}}
    temp_state = "CRIT" if temp >= crit else ("WARN" if temp >= warn else "OK")
    # dev_status takes precedence if in alarm ranges per source ordering
    if state != "OK":
        temp_state = state
    msg = "Description: %s, Status: %s, Temp: %s%s" % (
        data.get("descr", ""), status_name, _round(temp, 1), data.get("dev_unit", ""))
    return {"changed": False, "msg": msg,
            "data": {"state": temp_state, "metrics": {"temperature": temp},
                     "details": msg}}

def _probe_with(ctx, community, host):
    descr = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False)
    if descr.rc != 0:
        return None
    rows = _snmp_table(ctx, community, host, ".1.3.6.1.4.1.21796.4.1.3.1", ["1", "2", "3", "4", "7"])
    if len(rows) == 0:
        return {}
    return parse_hwg(rows)

def _round(v, n):
    s = "%.*f" % (n, v)
    return s