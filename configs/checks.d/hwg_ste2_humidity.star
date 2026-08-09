def _discover_common(section):
    out = []
    for index in section:
        data = section[index]
        if data.get("humidity") != None:
            out.append({"item": index, "params": {"levels": (60.0, 70.0)}, "metrics": ["humidity"]})
    return out

def _grade_humidity(value, warn, crit):
    if value == None:
        return "UNKNOWN"
    v = float(value)
    if v >= crit:
        return "CRIT"
    if v >= warn:
        return "WARN"
    return "OK"

def main(ctx, params):
    levels = params.get("levels", (60.0, 70.0))
    if type(levels) == "list":
        levels = tuple(levels)
    warn = levels[0] if len(levels) >= 1 else 60.0
    crit = levels[1] if len(levels) >= 2 else 70.0

    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-Oqn", params.get("host", "localhost"),
            ".1.3.6.1.4.1.21796.4.1.3.1.1",
        ], mutates=False)
        if res.rc != 0 or res.skipped:
            return {"changed": False, "msg": "no hwg_ste2 device found",
                    "data": {"discovery": [],
                             "host_labels": {"cmk/os_family": "linux"}}}

        section = {}
        base_col = ".1.3.6.1.4.1.21796.4.1.3.1"
        cols = {}
        for line in res.stdout.splitlines():
            sp = line.split(" ", 1)
            if len(sp) != 2:
                continue
            oid = sp[0]
            val = sp[1].strip().strip('"')
            suffix = oid[len(base_col):]
            parts = suffix.split(".")
            if len(parts) < 2:
                continue
            col = parts[0]
            idx = parts[1]
            cols.setdefault(idx, {})[col] = val

        for idx in cols:
            entry = cols[idx]
            descr = entry.get("2", "")
            sensorstatus = entry.get("3", "0")
            current = entry.get("4", "")
            unit = entry.get("1", "")
            map_units = {"1": "c", "2": "f", "3": "k", "4": "%"}
            map_dev_states = {
                "0": "invalid", "1": "normal",
                "2": "out of range low", "3": "out of range high",
                "4": "alarm low", "5": "alarm high",
            }
            descr_name = descr.strip().strip('"')
            if sensorstatus != "0" and map_units.get(unit, "") == "%":
                section[idx] = {
                    "descr": descr_name,
                    "humidity": float(current) if current.replace(".", "").isdigit() else None,
                    "dev_status_name": map_dev_states.get(sensorstatus, "n.a."),
                    "dev_status": sensorstatus,
                }
            else:
                section[idx] = {
                    "descr": descr_name,
                    "dev_unit": map_units.get(unit),
                    "temperature": float(current) if current.replace(".", "").isdigit() else None,
                    "dev_status_name": map_dev_states.get(sensorstatus, ""),
                    "dev_status": sensorstatus,
                }

        return {"changed": False, "msg": "discovered %d humidity sensors" % len(section),
                "data": {"discovery": _discover_common(section)}}

    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-Oqn", params.get("host", "localhost"),
        ".1.3.6.1.4.1.21796.4.1.3.1.1",
    ], mutates=False)
    if res.rc != 0 or res.skipped:
        return {"changed": False, "msg": "no hwg_ste2 device found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    cols = {}
    base_col = ".1.3.6.1.4.1.21796.4.1.3.1"
    for line in res.stdout.splitlines():
        sp = line.split(" ", 1)
        if len(sp) != 2:
            continue
        oid = sp[0]
        val = sp[1].strip().strip('"')
        suffix = oid[len(base_col):]
        parts = suffix.split(".")
        if len(parts) < 2:
            continue
        col = parts[0]
        idx = parts[1]
        cols.setdefault(idx, {})[col] = val

    if item not in cols:
        return {"changed": False, "msg": "no such humidity sensor: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    entry = cols[item]
    current = entry.get("4", "")
    descr = entry.get("2", "").strip().strip('"')
    sensorstatus = entry.get("3", "0")
    unit = entry.get("1", "")
    map_units = {"1": "c", "2": "f", "3": "k", "4": "%"}
    map_dev_states = {
        "0": "invalid", "1": "normal",
        "2": "out of range low", "3": "out of range high",
        "4": "alarm low", "5": "alarm high",
    }

    if sensorstatus == "0" or map_units.get(unit, "") != "%":
        return {"changed": False,
                "msg": "no humidity data: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    humidity = float(current) if current.replace(".", "").isdigit() else None
    state = _grade_humidity(humidity, warn, crit)
    metrics = {}
    if humidity != None:
        metrics["humidity"] = humidity
    details = "Description: " + descr + ", Status: " + map_dev_states.get(sensorstatus, "n.a.")
    return {"changed": False, "msg": details,
            "data": {"state": state, "metrics": metrics, "details": details}}