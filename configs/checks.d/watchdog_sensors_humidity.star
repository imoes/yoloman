def main(ctx, params):
    if params.get("_discover"):
        sysoid = _get_sysoid(ctx, params)
        if sysoid == "":
            return {"changed": False, "msg": "watchdog sensor not present",
                    "data": {"discovery": [], "host_labels": {}}}
        section = _fetch_section(ctx, params, sysoid)
        if section.get("humidity", {}) == {}:
            return {"changed": False, "msg": "no humidity sensors found",
                    "data": {"discovery": [], "host_labels": {}}}
        out = []
        for name in section["humidity"]:
            out.append({"item": name,
                        "params": {"levels": (50.0, 55.0), "levels_lower": (10.0, 15.0)},
                        "metrics": ["humidity"]})
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out, "host_labels": {}}}
    item = params.get("item", "")
    section = _fetch_section_cached(ctx, params)
    if section.get("humidity", {}) == {}:
        return {"changed": False, "msg": "no watchdog humidity sensor found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = section["humidity"].get(item)
    if data == None:
        return {"changed": False, "msg": "humidity sensor not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    humidity = int(data)
    levels = params.get("levels", (50.0, 55.0))
    levels_lower = params.get("levels_lower", (10.0, 15.0))
    warn = levels[0]
    crit = levels[1]
    warn_lower = levels_lower[0]
    crit_lower = levels_lower[1]
    state = "CRIT" if not ((crit_lower < humidity) and (humidity < crit)) else ("WARN" if not ((warn_lower < humidity) and (humidity < warn)) else "OK")
    summary = "%d%%" % humidity
    if state == "WARN":
        if humidity >= warn:
            summary += " (warn/crit at %s/%s)" % (_f(warn), _f(crit))
        else:
            summary += " (warn/crit below %s/%s)" % (_f(warn_lower), _f(crit_lower))
    elif state == "CRIT":
        if humidity >= crit:
            summary += " (warn/crit at %s/%s)" % (_f(warn), _f(crit))
        else:
            summary += " (warn/crit below %s/%s)" % (_f(warn_lower), _f(crit_lower))
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {"humidity": humidity}, "details": ""}}


def _f(v):
    iv = int(v)
    if float(v) == float(iv):
        return str(iv)
    return str(v)


def _get_sysoid(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"], mutates=False)
    if res.rc != 0:
        return ""
    base = res.stdout.strip()
    if not base.startswith(".1.3.6.1.4.1.21239.5.1") and not base.startswith(".1.3.6.1.4.1.21239.42.1"):
        return ""
    if base.startswith(".1.3.6.1.4.1.21239.42.1"):
        return ".1.3.6.1.4.1.21239.42.1"
    return ".1.3.6.1.4.1.21239.5.1"


def _fetch_section(ctx, params, sysoid):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    section = {"general": {}, "temp": {}, "humidity": {}, "dew": {}}
    gen_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqpe", host,
                       sysoid + ".1.1.2.0", sysoid + ".1.1.7.0"], mutates=False)
    if gen_res.rc != 0:
        return section
    gen_lines = [l for l in gen_res.stdout.splitlines() if l != ""]
    if len(gen_lines) < 2:
        return section
    version_str = gen_lines[0].split()[-1].strip('"')
    temp_unit_code = gen_lines[1].split()[-1].strip('"')
    temp_unit = "C"
    if temp_unit_code == "1":
        temp_unit = "C"
    elif temp_unit_code == "0":
        temp_unit = "F"
    version = int(version_str.replace(".", ""))
    walk_res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
                        sysoid + ".1.2.1"], mutates=False)
    if walk_res.rc != 0:
        return section
    rows = {}
    for line in walk_res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        value = parts[1].strip()
        if not oid.startswith(sysoid + ".1.2.1."):
            continue
        suffix = oid[len(sysoid + ".1.2.1."):]
        cols = suffix.split(".")
        sensor_id = cols[0]
        col = cols[1]
        rows.setdefault(sensor_id, {})[col] = value
    for sensor_id in rows:
        cols = rows[sensor_id]
        descr = cols.get("3", "")
        availability = cols.get("5", "")
        if version <= 300:
            humidity_val = cols.get("7", "")
        else:
            humidity_val = cols.get("5", "")
        key = "Watchdog " + sensor_id
        section["general"][key] = {"descr": descr, "availability": (availability,)}
        hkey = "Humidity " + sensor_id
        section["humidity"][hkey] = humidity_val
    return section


def _fetch_section_cached(ctx, params):
    sysoid = _get_sysoid(ctx, params)
    if sysoid == "":
        return {"general": {}, "temp": {}, "humidity": {}, "dew": {}}
    return _fetch_section(ctx, params, sysoid)