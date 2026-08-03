def main(ctx, params):
    if params.get("_discover"):
        section = _fetch_section(ctx, params)
        out = []
        for item in section:
            out.append({"item": item, "params": {"levels": [105.0, 110.0]},
                        "metrics": ["temperature"]})
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}
    item = params.get("item", "")
    section = _fetch_section(ctx, params)
    if item in section:
        value = section[item]
        warn, crit = _levels(params, 105.0, 110.0)
        state = "CRIT" if value >= crit else ("WARN" if value >= warn else "OK")
        return {"changed": False,
                "msg": "Temperature %s: %s" % (item, _fmt(value)),
                "data": {"state": state, "metrics": {"temperature": value},
                         "details": "%s: %s (levels: %s/%s)" %
                         (item, _fmt(value), _fmt(warn), _fmt(crit))}}
    if "Module" in item and "Sensor" not in item:
        return {"changed": False,
                "msg": "incompatible change, please re-discover this host",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    return {"changed": False,
            "msg": "no such temperature sensor: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}


def _fetch_section(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
                   ".1.3.6.1.4.1.1991.1.1.2.13.1.1.3"], mutates=False)
    if res.rc == 127 or not res.stdout:
        return {}
    col_oid = ".1.3.6.1.4.1.1991.1.1.2.13.1.1.3"
    descr_by_idx = {}
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        if not oid.startswith(col_oid + "."):
            continue
        index = oid[len(col_oid) + 1:]
        descr_by_idx[index] = parts[1]
    parsed = {}
    for index, descr in descr_by_idx.items():
        vres = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host,
                        ".1.3.6.1.4.1.1991.1.1.2.13.1.1.4." + index],
                       mutates=False)
        if vres.rc != 0 or not vres.stdout:
            continue
        temp_value = vres.stdout.strip()
        if temp_value and temp_value != "0":
            item = (descr.replace("temperature", "")
                    .replace("module", "Module")
                    .replace("sensor", "Sensor")
                    .replace(",", "")
                    .strip())
            parsed[item] = float(temp_value) * 0.5
    return parsed


def _levels(params, default_warn, default_crit):
    levels = params.get("levels")
    if levels != None:
        l = list(levels)
        if len(l) >= 2:
            return (float(l[0]), float(l[1]))
    return (default_warn, default_crit)


def _fmt(v):
    return "%f" % v