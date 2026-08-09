def main(ctx, params):
    if params.get("_discover"):
        sys_oid = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if sys_oid.rc != 0:
            return {"changed": False, "msg": "no SNMP agent",
                    "data": {"discovery": []}}
        sys_oid = sys_oid.stdout.strip()
        if not sys_oid.startswith(".1.3.6.1.4.1.2620"):
            return {"changed": False, "msg": "not a checkpoint device",
                    "data": {"discovery": []}}
        fw_oid = ctx.run(
            ["snmpget", "-v2c", "-c", params.get("community", "public"),
             "-Oqv", params.get("host", "localhost"),
             ".1.3.6.1.4.1.2620.1.1.21.0"],
            mutates=False,
        )
        if fw_oid.rc != 0:
            return {"changed": False, "msg": "no firewall product OID",
                    "data": {"discovery": []}}
        fw_val = fw_oid.stdout.strip()
        if not fw_val.startswith("firewall"):
            gaia_oid = ctx.run(
                ["snmpget", "-v2c", "-c", params.get("community", "public"),
                 "-Oqv", params.get("host", "localhost"),
                 ".1.3.6.1.4.1.2620.1.6.5.1.0"],
                mutates=False,
            )
            if gaia_oid.rc != 0:
                return {"changed": False, "msg": "not a checkpoint device",
                        "data": {"discovery": []}}
            if not gaia_oid.stdout.strip() == "Gaia":
                return {"changed": False, "msg": "not a checkpoint device",
                        "data": {"discovery": []}}
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
             "-Oqn", params.get("host", "localhost"),
             ".1.3.6.1.4.1.2620.1.6.7.8.1.1"],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False, "msg": "no temperature sensors",
                    "data": {"discovery": []}}
        col_oid = ".1.3.6.1.4.1.2620.1.6.7.8.1.1"
        rows = {}
        for line in res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid_full, raw_val = parts[0], parts[1]
            if not oid_full.startswith(col_oid + "."):
                continue
            suffix = oid_full[len(col_oid) + 1:]
            sub = suffix.split(".")
            if len(sub) != 1:
                continue
            rows[suffix] = raw_val
        sensors = _parse_temp_sensors(rows)
        if not sensors:
            return {"changed": False, "msg": "no temperature sensors",
                    "data": {"discovery": []}}
        out = []
        for name, _value, _unit, _status in sensors:
            item = _format_item(name)
            if item == "":
                continue
            out.append({"item": item, "params": {"warn": 50.0, "crit": 60.0},
                        "metrics": ["temperature"]})
        return {"changed": False,
                "msg": "discovered %d temperature sensors" % len(out),
                "data": {"discovery": out}}
    item = params.get("item", "")
    base = ".1.3.6.1.4.1.2620.1.6.7.8.1.1"
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", params.get("community", "public"),
         "-Oqn", params.get("host", "localhost"), base],
        mutates=False,
    )
    if res.rc != 0:
        return {"changed": False, "msg": "no temperature sensors",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    rows = {}
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid_full, raw_val = parts[0], parts[1]
        if not oid_full.startswith(base + "."):
            continue
        suffix = oid_full[len(base) + 1:]
        sub = suffix.split(".")
        if len(sub) != 1:
            continue
        rows[suffix] = raw_val
    sensors = _parse_temp_sensors(rows)
    match = None
    for name, value, unit, dev_status in sensors:
        if _format_item(name) == item:
            match = (name, value, unit, dev_status)
            break
    if match == None:
        return {"changed": False, "msg": "no such sensor: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    name, value, unit, dev_status = match
    state, state_readable = _sensor_status(dev_status)
    if value == "":
        return {"changed": False,
                "msg": "Status: " + state_readable,
                "data": {"state": state, "metrics": {}, "details": ""}}
    warn = params.get("warn", 50.0)
    crit = params.get("crit", 60.0)
    levels = params.get("levels", (warn, crit))
    if type(levels) == "list":
        if len(levels) >= 2:
            warn = levels[0]
            crit = levels[1]
    numeric = 0.0
    try_v = float(value) if value.replace(".", "", 1).replace("-", "", 1).isdigit() else None
    if try_v != None:
        numeric = try_v
    threshold = _grade_temperature(numeric, warn, crit)
    if state == "OK" and threshold != "OK":
        final_state = threshold
    else:
        final_state = state
    unit_clean = unit.replace("degree", "").strip().lower()
    return {"changed": False,
            "msg": "%s: %f %s (%s)" % (item, numeric, unit_clean, state_readable),
            "data": {"state": final_state,
                     "metrics": {"temperature": numeric},
                     "details": ""}}


def _format_item(name):
    return name.upper().replace(" TEMP", "")


def _sensor_status(dev_status):
    table = {"0": ("OK", "sensor in range"),
             "1": ("CRIT", "sensor out of range"),
             "2": ("UNKNOWN", "reading error")}
    entry = table.get(dev_status, ("UNKNOWN", "unknown status"))
    return entry


def _grade_temperature(value, warn, crit):
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"


def _parse_temp_sensors(rows):
    col_name = "2"
    col_value = "3"
    col_unit = "4"
    col_status = "6"
    by_index = {}
    for oid_suffix, raw_val in rows.items():
        sub = oid_suffix.split(".")
        if len(sub) != 2:
            continue
        col, idx = sub[0], sub[1]
        entry = by_index.get(idx)
        if entry == None:
            entry = {"name": None, "value": None, "unit": None, "status": None}
        if col == col_name:
            entry["name"] = _strip_quotes(raw_val)
        elif col == col_value:
            entry["value"] = _strip_quotes(raw_val)
        elif col == col_unit:
            entry["unit"] = _strip_quotes(raw_val)
        elif col == col_status:
            entry["status"] = _strip_quotes(raw_val)
        by_index[idx] = entry
    result = []
    for idx, entry in by_index.items():
        if entry["name"] == None:
            continue
        result.append((entry["name"],
                       entry["value"] if entry["value"] != None else "",
                       entry["unit"] if entry["unit"] != None else "",
                       entry["status"] if entry["status"] != None else "0"))
    return result


def _strip_quotes(s):
    if s == None:
        return s
    s = s.strip()
    if len(s) >= 2 and s[0] == '"' and s[len(s) - 1] == '"':
        return s[1:len(s) - 1]
    return s