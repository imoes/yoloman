def _pow(b, e):
    if e == 0:
        return 1.0
    if e < 0:
        b = 1.0 / b
        e = -e
    result = 1.0
    n = e
    for _ in range(n):
        result = result * b
    return result


def _is_bluecoat(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if res.rc != 0:
        return False
    sys_oid = res.stdout.strip()
    if sys_oid.startswith("1.3.6.1.4.1.3417.1.1"):
        return True
    return False


def _fetch_sensors(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.3417.2.1.1.1.1.1"
    cols = [
        ("name", ".9"),
        ("reading", ".5"),
        ("status", ".7"),
        ("scale", ".4"),
        ("unit", ".3"),
    ]
    name_col_oid = base + ".9"
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, name_col_oid],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout.strip():
        return []
    sensors = {}
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid, val = parts[0], parts[1]
        idx = oid[len(base) + 1 + len(".9"):]
        if not idx:
            continue
        if idx not in sensors:
            sensors[idx] = {}
        sensors[idx]["name"] = val.strip().strip('"')
    if not sensors:
        return []
    for key, suffix in cols:
        if key == "name":
            continue
        col_oid = base + suffix
        res2 = ctx.run(
            ["snmpbulkwalk", "-v2c", "-c", community, "-Oqn", host, col_oid],
            mutates=False,
        )
        if res2.rc != 0 or not res2.stdout.strip():
            res2 = ctx.run(
                ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_oid],
                mutates=False,
            )
        for line in res2.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            oid, val = parts[0], parts[1]
            matched_idx = ""
            for idx in sensors:
                prefix_test = col_oid + "." + idx
                if oid.startswith(prefix_test):
                    matched_idx = idx
                    break
            if matched_idx and matched_idx in sensors:
                sensors[matched_idx][key] = val.strip().strip('"')
    result = []
    for idx in sensors:
        cols_map = sensors[idx]
        if "reading" not in cols_map or "status" not in cols_map or "scale" not in cols_map or "unit" not in cols_map:
            continue
        result.append({
            "name": cols_map["name"],
            "reading": cols_map["reading"],
            "status": cols_map["status"],
            "scale": cols_map["scale"],
            "unit": cols_map["unit"],
        })
    return result


def _parse_float(s):
    if s == None or s == "":
        return None
    cleaned = s.strip().strip('"').strip()
    if cleaned == "" or cleaned == "-":
        return None
    neg = cleaned.startswith("-")
    body = cleaned[1:] if neg else cleaned
    if "." in body:
        int_part, frac_part = body.split(".", 1)
        if int_part == "" and frac_part == "":
            return None
        if int_part != "" and not int_part.isdigit():
            return None
        if frac_part != "" and not frac_part.isdigit():
            return None
    else:
        if not body.isdigit():
            return None
    return float(cleaned)


def main(ctx, params):
    if params.get("_discover"):
        if not _is_bluecoat(ctx, params):
            return {
                "changed": False,
                "msg": "device not detected as Bluecoat/Symantec",
                "data": {"discovery": []},
            }
        sensors = _fetch_sensors(ctx, params)
        temp_names = []
        for s in sensors:
            if s.get("unit") == "5":
                sensor_name = s.get("name", "").replace(" temperature", "")
                if sensor_name and sensor_name not in temp_names:
                    temp_names.append(sensor_name)
        discovery = []
        for name in temp_names:
            discovery.append({
                "item": name,
                "params": {"device_levels_handling": "devdefault"},
                "metrics": ["temperature"],
            })
        return {
            "changed": False,
            "msg": "discovered %d temperature sensors" % len(temp_names),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    if not _is_bluecoat(ctx, params):
        return {
            "changed": False,
            "msg": "device not detected as Bluecoat/Symantec",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    sensors = _fetch_sensors(ctx, params)
    sensor_map = {}
    for s in sensors:
        if s.get("unit") == "5":
            sensor_name = s.get("name", "").replace(" temperature", "")
            sensor_map[sensor_name] = s

    if item not in sensor_map:
        return {
            "changed": False,
            "msg": "no such temperature sensor: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    s = sensor_map[item]
    reading_val = _parse_float(s.get("reading", ""))
    scale_val = _parse_float(s.get("scale", ""))
    if reading_val == None or scale_val == None:
        return {
            "changed": False,
            "msg": "could not parse sensor value for %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    value = reading_val * _pow(10.0, scale_val)
    is_ok = s.get("status") == "1"
    warn = params.get("warn", 30)
    crit = params.get("crit", 40)
    lower_warn = params.get("lower_warn")
    lower_crit = params.get("lower_crit")

    if not is_ok:
        state = "CRIT"
    elif value >= crit:
        state = "CRIT"
    elif value >= warn:
        state = "WARN"
    elif lower_crit != None and value <= lower_crit:
        state = "CRIT"
    elif lower_warn != None and value <= lower_warn:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": "Temperature %s: %f" % (item, value),
        "data": {
            "state": state,
            "metrics": {"temperature": value},
            "details": "Device status: %s" % ("OK" if is_ok else "Not OK"),
        },
    }